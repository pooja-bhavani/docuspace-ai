#!/bin/bash
# DocuSpace AI - Complete Project Bootstrapper
# This script scaffolds the complete React frontend, Node.js API, and Python Worker.

echo "🚀 Bootstrapping DocuSpace AI Workspace..."

# 1. Create directory structures
mkdir -p web/src/components api/src worker

# 2. Create README.md
cat << 'EOF' > README.md
# 🚀 DocuSpace AI: High-Throughput Semantic Document Space

DocuSpace AI is a complete, production-ready document search and AI retrieval (RAG) platform. It leverages a fully custom 7-service architecture on Zerops.

## 🏗️ Architecture
1. **Frontend (web)**: React / Vite / Tailwind served by Nginx.
2. **API (api)**: TypeScript Express server coordinating databases and S3 storage.
3. **Worker (worker)**: Python background consumer extracting text, generating embeddings locally, and indexing to Qdrant.
4. **PostgreSQL (db)**: Storage for structural document metadata.
5. **Qdrant (vector)**: High-speed vector similarity database.
6. **NATS (queue)**: High-performance message queue for asynchronous decoupling.
7. **S3 Storage (storage)**: S3-compatible file persistence.
EOF

# 3. Create zerops.yaml
cat << 'EOF' > zerops.yaml
zerops:
  - setup: web
    build:
      base: nodejs@20
      buildCommands:
        - cd web && npm install
        - cd web && npm run build
      deployFiles:
        - ./web/dist
    run:
      base: nginx@latest
      documentRoot: /var/www/web/dist
      ports:
        - port: 80
          httpSupport: true

  - setup: api
    build:
      base: nodejs@20
      buildCommands:
        - cd api && npm install
        - cd api && npm run build
      deployFiles:
        - ./api/dist
        - ./api/node_modules
        - ./api/package.json
    run:
      base: nodejs@20
      ports:
        - port: 3000
          httpSupport: true
      start: node api/dist/server.js
      healthCheck:
        httpGet:
          port: 3000
          path: /health

  - setup: worker
    build:
      base: python@3.11
      buildCommands:
        - cd worker && pip install -r requirements.txt
      deployFiles:
        - ./worker
    run:
      base: python@3.11
      os: ubuntu
      prepareCommands:
        - sudo apt-get update
        - sudo apt-get install -y poppler-utils tesseract-ocr pandoc libtesseract-dev
      start: python worker/main.py
EOF

# 4. Create API configurations
cat << 'EOF' > api/package.json
{
  "name": "docuspace-api",
  "version": "1.0.0",
  "main": "dist/server.js",
  "scripts": {
    "build": "tsc",
    "start": "node dist/server.js"
  },
  "dependencies": {
    "@aws-sdk/client-s3": "^3.500.0",
    "@qdrant/js-client-rest": "^1.7.0",
    "cors": "^2.8.5",
    "dotenv": "^16.4.0",
    "express": "^4.18.2",
    "multer": "^1.4.5-lts.1",
    "nats": "^2.19.0",
    "pg": "^8.11.3"
  },
  "devDependencies": {
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/multer": "^1.4.11",
    "@types/node": "^20.11.16",
    "@types/pg": "^8.11.0",
    "typescript": "^5.3.3"
  }
}
EOF

cat << 'EOF' > api/tsconfig.json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "rootDir": "./src",
    "outDir": "./dist",
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*"]
}
EOF

cat << 'EOF' > api/src/server.ts
import express from 'express';
import cors from 'cors';
import multer from 'multer';
import { Pool } from 'pg';
import { connect, JSONCodec } from 'nats';
import { QdrantClient } from '@qdrant/js-client-rest';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import * as fs from 'fs';

const app = express();
app.use(cors());
app.use(express.json());

const upload = multer({ dest: '/tmp/uploads/' });
const jc = JSONCodec();

// System environment variable injection
const pool = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  port: 5432
});

const qdrant = new QdrantClient({
  url: process.env.QDRANT_URL || 'http://vector:6333'
});

const s3 = new S3Client({
  endpoint: process.env.S3_ENDPOINT,
  region: 'us-east-1',
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY || '',
    secretAccessKey: process.env.S3_SECRET_KEY || ''
  },
  forcePathStyle: true
});

// Initialize Schema
async function initDB() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS documents (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name VARCHAR(255) NOT NULL,
        storage_key VARCHAR(555) NOT NULL,
        status VARCHAR(50) NOT NULL DEFAULT 'processing',
        created_at TIMESTAMPTZ DEFAULT NOW()
      );
    `);
    console.log('✅ PostgreSQL schema successfully initialised.');
  } catch (err) {
    console.error('❌ Failed to initialise database:', err);
  }
}
initDB();

// Health Check for Zerops readiness
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'UP' });
});

// Fetch documents list
app.get('/api/documents', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM documents ORDER BY created_at DESC');
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve documents.' });
  }
});

// Handle PDF/DOCX file upload
app.post('/api/upload', upload.single('file'), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: 'No file uploaded.' });
  }

  const { originalname, path } = req.file;
  const storageKey = `uploads/${Date.now()}-${originalname}`;

  try {
    // 1. Save file metadata to PG
    const dbResult = await pool.query(
      'INSERT INTO documents (name, storage_key, status) VALUES ($1, $2, $3) RETURNING *',
      [originalname, storageKey, 'processing']
    );
    const document = dbResult.rows[0];

    // 2. Upload file binary to S3
    const fileStream = fs.createReadStream(path);
    await s3.send(new PutObjectCommand({
      Bucket: process.env.S3_BUCKET || 'docuspace-files',
      Key: storageKey,
      Body: fileStream,
      ContentType: req.file.mimetype
    }));

    // 3. Publish extraction task to NATS Queue
    const natsConn = await connect({ servers: process.env.NATS_URL || 'nats://queue:4222' });
    natsConn.publish('document.parse', jc.encode({
      documentId: document.id,
      storageKey: storageKey,
      name: originalname
    }));
    await natsConn.drain();

    // Cleanup local temp file
    fs.unlinkSync(path);

    res.status(202).json(document);
  } catch (err) {
    console.error('❌ Upload failure:', err);
    res.status(500).json({ error: 'Upload transaction failed.' });
  }
});

// Semantic search and QA endpoint
app.post('/api/chat', async (req, res) => {
  const { query, documentId } = req.body;
  if (!query) return res.status(400).json({ error: 'Query required.' });

  try {
    // 1. Connect NATS and request query embedding from python worker
    const natsConn = await connect({ servers: process.env.NATS_URL || 'nats://queue:4222' });
    const response = await natsConn.request('embeddings.generate', jc.encode({ text: query }), { timeout: 5000 });
    const { embedding } = jc.decode(response.data) as { embedding: number[] };
    await natsConn.drain();

    // 2. Perform Cosine Similarity Search in Qdrant
    const searchResult = await qdrant.search('documents', {
      vector: embedding,
      filter: documentId ? {
        must: [{ key: 'document_id', match: { value: documentId } }]
      } : undefined,
      limit: 3,
      with_payload: true
    });

    // 3. Compile matched text blocks
    const contexts = searchResult.map(hit => hit.payload?.text || '').join('\n\n');

    // Send context, hits and a generated synthesis back to frontend
    res.json({
      answer: contexts ? `Here is the relevant information extracted from your documents:\n\n${contexts}` : "No matches found in your document database.",
      sources: searchResult.map(hit => ({
        text: hit.payload?.text,
        score: hit.score,
        documentId: hit.payload?.document_id
      }))
    });
  } catch (err) {
    console.error('❌ Search failure:', err);
    res.status(500).json({ error: 'Semantic search failed.' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`🚀 API active on port ${PORT}`));
EOF

# 5. Create Worker configurations
cat << 'EOF' > worker/requirements.txt
nats-py==2.7.2
psycopg2-binary==2.9.9
qdrant-client==1.7.0
sentence-transformers==2.3.1
pypdf==4.0.1
boto3==1.34.34
EOF

cat << 'EOF' > worker/main.py
import os
import json
import asyncio
import boto3
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
    aws_secret_access_key=os.getenv("S3_SECRET_KEY")
)

def get_db_connection():
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        database=os.getenv("DB_NAME", "db"),
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
        except:
            pass
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
EOF

# 6. Create Frontend configurations
cat << 'EOF' > web/package.json
{
  "name": "docuspace-web",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "lucide-react": "^0.321.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@types/react": "^18.2.43",
    "@types/react-dom": "^18.2.17",
    "@vitejs/plugin-react": "^4.2.1",
    "autoprefixer": "^10.4.16",
    "postcss": "^8.4.33",
    "tailwindcss": "^3.4.1",
    "typescript": "^5.2.2",
    "vite": "^5.0.8"
  }
}
EOF

cat << 'EOF' > web/vite.config.ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    host: true
  }
})
EOF

cat << 'EOF' > web/postcss.config.js
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
EOF

cat << 'EOF' > web/tailwind.config.js
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}
EOF

cat << 'EOF' > web/index.html
<!doctype html>
<html lang="en" class="dark bg-slate-950 text-slate-100">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>DocuSpace AI</title>
    <script src="https://cdn.tailwindcss.com"></script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
EOF

cat << 'EOF' > web/src/main.tsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.tsx'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
EOF

cat << 'EOF' > web/src/App.tsx
import React, { useState, useEffect } from 'react';
import { Upload, MessageSquare, ShieldAlert, CheckCircle2, RefreshCw, Database, Sparkles } from 'lucide-react';

interface Document {
  id: string;
  name: string;
  status: 'processing' | 'completed' | 'failed';
  created_at: string;
}

interface Source {
  text: string;
  score: number;
  documentId: string;
}

export default function App() {
  const [docs, setDocuments] = useState<Document[]>([]);
  const [activeDoc, setActiveDoc] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [chatLog, setChatLog] = useState<{ role: 'user' | 'assistant'; text: string; sources?: Source[] }[]>([]);
  const [uploading, setUploading] = useState(false);
  const [loading, setLoading] = useState(false);

  // Auto-resolve backend API address dynamically at runtime
  const API_BASE = window.location.origin.includes('5173') ? 'http://localhost:3000' : '';

  const fetchDocs = async () => {
    try {
      const res = await fetch(`${API_BASE}/api/documents`);
      const data = await res.json();
      setDocuments(data);
    } catch (e) {
      console.error(e);
    }
  };

  useEffect(() => {
    fetchDocs();
    const interval = setInterval(fetchDocs, 5000);
    return () => clearInterval(interval);
  }, []);

  const handleUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    if (!e.target.files?.[0]) return;
    setUploading(true);
    const formData = new FormData();
    formData.append('file', e.target.files[0]);

    try {
      await fetch(`${API_BASE}/api/upload`, { method: 'POST', body: formData });
      fetchDocs();
    } catch (err) {
      console.error(err);
    } finally {
      setUploading(false);
    }
  };

  const handleSearch = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!query.trim()) return;

    setLoading(true);
    setChatLog(prev => [...prev, { role: 'user', text: query }]);
    const currentQuery = query;
    setQuery('');

    try {
      const res = await fetch(`${API_BASE}/api/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: currentQuery, documentId: activeDoc })
      });
      const data = await res.json();
      setChatLog(prev => [...prev, { role: 'assistant', text: data.answer, sources: data.sources }]);
    } catch (err) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex h-screen bg-slate-950 font-sans text-slate-100 overflow-hidden">
      {/* Document Sidebar */}
      <div className="w-80 border-r border-slate-800 bg-slate-900 flex flex-col p-6 space-y-6">
        <div className="flex items-center space-x-2">
          <Database className="h-6 w-6 text-teal-400" />
          <h1 className="font-bold text-xl tracking-tight">DocuSpace <span className="text-teal-400">AI</span></h1>
        </div>

        {/* Upload Container */}
        <label className="border-2 border-dashed border-slate-700 hover:border-teal-500 hover:bg-slate-800/40 rounded-xl p-6 text-center cursor-pointer transition flex flex-col items-center justify-center space-y-2">
          {uploading ? <RefreshCw className="h-8 w-8 text-teal-400 animate-spin" /> : <Upload className="h-8 w-8 text-teal-400" />}
          <span className="font-medium text-sm">Upload PDF</span>
          <span className="text-xs text-slate-400">PDF to vector engine</span>
          <input type="file" onChange={handleUpload} className="hidden" accept=".pdf" />
        </label>

        {/* Library Lists */}
        <div className="flex-1 flex flex-col space-y-3 overflow-y-auto">
          <h2 className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Indexed Documents</h2>
          <div className="space-y-2">
            <button 
              onClick={() => setActiveDoc(null)}
              className={`w-full text-left p-3 rounded-lg text-sm transition flex items-center justify-between ${!activeDoc ? 'bg-teal-500/10 border border-teal-500/30 text-teal-300' : 'bg-slate-800 hover:bg-slate-700'}`}
            >
              <span className="font-medium">All Knowledge Bases</span>
            </button>
            {docs.map(doc => (
              <button
                key={doc.id}
                onClick={() => doc.status === 'completed' && setActiveDoc(doc.id)}
                disabled={doc.status !== 'completed'}
                className={`w-full text-left p-3 rounded-lg text-sm transition flex items-center justify-between ${activeDoc === doc.id ? 'bg-teal-500/10 border border-teal-500/30 text-teal-300' : 'bg-slate-800 disabled:opacity-60 hover:bg-slate-700'}`}
              >
                <div className="truncate pr-2 flex-1">
                  <p className="font-medium truncate">{doc.name}</p>
                  <p className="text-xxs text-slate-400">PDF</p>
                </div>
                <div>
                  {doc.status === 'processing' && <RefreshCw className="h-4 w-4 text-amber-400 animate-spin" />}
                  {doc.status === 'completed' && <CheckCircle2 className="h-4 w-4 text-emerald-400" />}
                  {doc.status === 'failed' && <ShieldAlert className="h-4 w-4 text-rose-500" />}
                </div>
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Main RAG Engine Interface */}
      <div className="flex-1 flex flex-col h-full bg-slate-950">
        <div className="h-16 border-b border-slate-800 px-8 flex items-center justify-between bg-slate-900/40">
          <div className="flex items-center space-x-2 text-slate-300">
            <Sparkles className="h-4 w-4 text-teal-400" />
            <span className="text-sm font-semibold">Semantic Space Workspace</span>
          </div>
          <div className="text-xxs px-3 py-1 bg-slate-800 border border-slate-700 rounded-full text-slate-400 font-mono">
            Mode: ZCP Bare-Metal RAG
          </div>
        </div>

        {/* Chat log window */}
        <div className="flex-1 overflow-y-auto p-8 space-y-6">
          {chatLog.length === 0 ? (
            <div className="h-full flex flex-col items-center justify-center text-center space-y-4 max-w-md mx-auto">
              <div className="p-4 bg-slate-900/60 border border-slate-800 rounded-full">
                <MessageSquare className="h-10 w-10 text-teal-400" />
              </div>
              <h2 className="font-bold text-lg">Empty Semantic Space</h2>
              <p className="text-sm text-slate-400 leading-relaxed">
                Upload a document in the sidebar to begin. The background Python worker parses your files asynchronously, runs sentence-transformer models locally, and pushes vectors directly to Qdrant.
              </p>
            </div>
          ) : (
            chatLog.map((log, i) => (
              <div key={i} className={`flex ${log.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                <div className={`max-w-3xl rounded-xl p-6 leading-relaxed text-sm ${log.role === 'user' ? 'bg-teal-500/10 border border-teal-500/20 text-teal-300' : 'bg-slate-900 border border-slate-800'}`}>
                  <p className="whitespace-pre-wrap">{log.text}</p>
                  
                  {log.sources && log.sources.length > 0 && (
                    <div className="mt-4 pt-4 border-t border-slate-800">
                      <h3 className="text-xxs font-bold text-slate-400 uppercase tracking-widest mb-2">Sources Extracted</h3>
                      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                        {log.sources.map((src, index) => (
                          <div key={index} className="bg-slate-950 p-3 rounded-lg border border-slate-800">
                            <p className="text-xs text-slate-300 italic">"...{src.text.slice(0, 140)}..."</p>
                            <p className="text-xxs text-teal-400 font-semibold mt-2">Cosine Score: {src.score.toFixed(4)}</p>
                          </div>
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              </div>
            ))
          )}
        </div>

        {/* Input box */}
        <div className="p-8 bg-slate-900/20 border-t border-slate-800">
          <form onSubmit={handleSearch} className="flex space-y-0 max-w-4xl mx-auto bg-slate-900 border border-slate-800 rounded-xl overflow-hidden focus-within:ring-2 focus-within:ring-teal-500 transition">
            <input 
              type="text" 
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Ask anything about your document catalog..."
              className="flex-1 bg-transparent px-6 py-4 text-sm focus:outline-none placeholder-slate-500"
              disabled={loading}
            />
            <button 
              type="submit" 
              className="bg-teal-500 hover:bg-teal-600 transition text-slate-950 px-6 font-semibold text-sm flex items-center justify-center"
              disabled={loading}
            >
              {loading ? 'Thinking...' : 'Query'}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
EOF

chmod +x setup.sh
echo "✅ Scaffolding successfully finished! Execute './setup.sh' to write all local files instantly."
