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
 
 
