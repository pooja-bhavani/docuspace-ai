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
    const document = dbResult.rows;

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

    // 3. Compile matched text blocks (cast payload to bypass strict TypeScript unknown index signatures)
    const contexts = searchResult.map(hit => (hit.payload as any)?.text || '').join('\n\n');

    // Send context, hits and a generated synthesis back to frontend
    res.json({
      answer: contexts ? `Here is the relevant information extracted from your documents:\n\n${contexts}` : "No matches found in your document database.",
      sources: searchResult.map(hit => ({
        text: (hit.payload as any)?.text,
        score: hit.score,
        documentId: (hit.payload as any)?.document_id
      }))
    });
  } catch (err) {
    console.error('❌ Search failure:', err);
    res.status(500).json({ error: 'Semantic search failed.' });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`🚀 API active on port ${PORT}`));
