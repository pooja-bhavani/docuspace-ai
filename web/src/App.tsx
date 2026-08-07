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
