import os
import json
import asyncio
import boto3
from botocore.client import Config
from nats.aio.client import Client as NATS
import psycopg2
from qdrant_client import QdrantClient
from qdrant_client.http import models
from sentence_transformers import SentenceTransformer
from pypdf import PdfReader

print("🧠 Loading local sentence-transformer (all-MiniLM-L6-v2) embedding model...")
model = SentenceTransformer('all-MiniLM-L6-v2')

# Setup connections
qdrant = QdrantClient(url=os.getenv("QDRANT_URL", "http://vector:6333"))

s3 = boto3.client(
    's3',
    endpoint_url=os.getenv("S3_ENDPOINT"),
    aws_access_key_id=os.getenv("S3_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("S3_SECRET_KEY"),
    config=Config(s3={'addressing_style': 'path'}),  # Force path-style addressing for private network resolution
    region_name='us-east-1'
)

def get_db_connection():
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        database=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
        port=5432
    )

# Initialise Qdrant collection on startup
def init_qdrant():
    try:
        collections = qdrant.get_collections().collections
        exists = any(c.name == "documents" for c in collections)
        if not exists:
            qdrant.create_collection(
                collection_name="documents",
                vectors_config=models.VectorParams(size=384, distance=models.Distance.COSINE)
            )
            print("✅ Created Qdrant collection 'documents'")
    except Exception as e:
        print(f"⚠️ Qdrant init warning: {e}")

init_qdrant()

async def process_document(msg):
    data = json.loads(msg.data.decode())
    doc_id = data['documentId']
    storage_key = data['storageKey']
    filename = data['name']
    
    print(f"📥 Fetching & parsing file: {filename}...")
    local_path = f"/tmp/{doc_id}.pdf"
    
    try:
        # 1. Download file from S3
        s3.download_file(
            os.getenv("S3_BUCKET", "docuspace-files"),
            storage_key,
            local_path
        )
        
        # 2. Extract PDF Text (Simple chunking)
        reader = PdfReader(local_path)
        chunks = []
        for i, page in enumerate(reader.pages):
            text = page.extract_text()
            if text and len(text.strip()) > 50:
                chunks.append({
                    "text": text.strip(),
                    "page": i + 1
                })
                
        # 3. Embed & Upload to Qdrant
        points = []
        for index, chunk in enumerate(chunks):
            vector = model.encode(chunk['text']).tolist()
            points.append(models.PointStruct(
                id=f"{doc_id}-{index}",
                vector=vector,
                payload={
                    "text": chunk['text'],
                    "page": chunk['page'],
                    "document_id": doc_id,
                    "filename": filename
                }
            ))
            
        if points:
            qdrant.upsert(collection_name="documents", points=points)
            
        # 4. Update Postgres state to Completed
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            "UPDATE documents SET status = %s WHERE id = %s",
            ('completed', doc_id)
        )
        conn.commit()
        cur.close()
        conn.close()
        
        print(f"✅ Document {filename} processed successfully! Indexed {len(points)} vectors.")
        
    except Exception as e:
        print(f"❌ Failed to parse document: {e}")
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute(
                "UPDATE documents SET status = %s WHERE id = %s",
                ('failed', doc_id)
            )
            conn.commit()
            cur.close()
            conn.close()
        except Exception as db_err:
            print(f"❌ Failed to write failure state to database: {db_err}")
    finally:
        if os.path.exists(local_path):
            os.remove(local_path)

async def reply_embedding(msg):
    data = json.loads(msg.data.decode())
    text = data.get('text', '')
    vector = model.encode(text).tolist()
    await msg.respond(json.dumps({"embedding": vector}).encode())

async def main():
    nc = NATS()
    print("📡 Worker connecting to NATS...")
    await nc.connect(os.getenv("NATS_URL", "nats://queue:4222"))
    print("✅ Connected to NATS broker.")
    
    # Subscribe to Async Document Parsing
    await nc.subscribe("document.parse", cb=process_document, queue="workers")
    
    # Subscribe to Query Embedding Generation (Request-Reply Pattern)
    await nc.subscribe("embeddings.generate", cb=reply_embedding)
    
    # Keep event loop running
    while True:
        await asyncio.sleep(1)

if __name__ == "__main__":
    asyncio.run(main())
