const express = require("express");
const cors = require("cors");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();
const PORT = process.env.PORT || 3001;

// ── Middleware ──
app.use(cors());
app.use(express.json());

// ── PostgreSQL Connection ──
const pool = new Pool({
  host: process.env.PG_HOST || "postgres",
  port: parseInt(process.env.PG_PORT || "5432"),
  user: process.env.POSTGRES_USER || "admin",
  password: process.env.POSTGRES_PASSWORD || "password123",
  database: process.env.POSTGRES_DB || "cloudnative",
});

// ── Redis Connection ──
const redis = new Redis({
  host: process.env.REDIS_HOST || "redis",
  port: parseInt(process.env.REDIS_PORT || "6379"),
  maxRetriesPerRequest: 3,
  retryStrategy: (times) => Math.min(times * 200, 2000),
});

redis.on("error", (err) => console.error("Redis connection error:", err.message));

// ── Initialize Database Table ──
async function initDB() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS tasks (
        id SERIAL PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        description TEXT,
        status VARCHAR(50) DEFAULT 'pending',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    console.log("Database initialized: tasks table ready");
  } catch (err) {
    console.error("Database initialization error:", err.message);
  }
}

// ── Cache Helper ──
async function getCached(key) {
  try {
    const cached = await redis.get(key);
    return cached ? JSON.parse(cached) : null;
  } catch {
    return null;
  }
}

async function setCache(key, data, ttl = 30) {
  try {
    await redis.setex(key, ttl, JSON.stringify(data));
  } catch (err) {
    console.error("Cache set error:", err.message);
  }
}

async function clearCache(pattern) {
  try {
    const keys = await redis.keys(pattern);
    if (keys.length > 0) await redis.del(...keys);
  } catch (err) {
    console.error("Cache clear error:", err.message);
  }
}

// ══════════════════════════════════════════
//  ROUTES
// ══════════════════════════════════════════

// Health check — used by Kubernetes readiness/liveness probes
app.get("/api/health", async (req, res) => {
  const health = { status: "healthy", timestamp: new Date().toISOString() };

  try {
    await pool.query("SELECT 1");
    health.postgres = "connected";
  } catch {
    health.postgres = "disconnected";
    health.status = "degraded";
  }

  try {
    await redis.ping();
    health.redis = "connected";
  } catch {
    health.redis = "disconnected";
    health.status = "degraded";
  }

  const statusCode = health.status === "healthy" ? 200 : 503;
  res.status(statusCode).json(health);
});

// GET /api/tasks — List all tasks (with Redis caching)
app.get("/api/tasks", async (req, res) => {
  try {
    const cached = await getCached("tasks:all");
    if (cached) {
      return res.json({ source: "cache", data: cached });
    }

    const result = await pool.query(
      "SELECT * FROM tasks ORDER BY created_at DESC"
    );
    await setCache("tasks:all", result.rows);
    res.json({ source: "database", data: result.rows });
  } catch (err) {
    console.error("GET /api/tasks error:", err.message);
    res.status(500).json({ error: "Failed to fetch tasks" });
  }
});

// POST /api/tasks — Create a new task
app.post("/api/tasks", async (req, res) => {
  const { title, description } = req.body;
  if (!title) {
    return res.status(400).json({ error: "Title is required" });
  }

  try {
    const result = await pool.query(
      "INSERT INTO tasks (title, description) VALUES ($1, $2) RETURNING *",
      [title, description || ""]
    );
    await clearCache("tasks:*");
    res.status(201).json({ data: result.rows[0] });
  } catch (err) {
    console.error("POST /api/tasks error:", err.message);
    res.status(500).json({ error: "Failed to create task" });
  }
});

// PUT /api/tasks/:id — Update a task
app.put("/api/tasks/:id", async (req, res) => {
  const { id } = req.params;
  const { title, description, status } = req.body;

  try {
    const result = await pool.query(
      `UPDATE tasks 
       SET title = COALESCE($1, title), 
           description = COALESCE($2, description), 
           status = COALESCE($3, status),
           updated_at = CURRENT_TIMESTAMP
       WHERE id = $4 RETURNING *`,
      [title, description, status, id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: "Task not found" });
    }

    await clearCache("tasks:*");
    res.json({ data: result.rows[0] });
  } catch (err) {
    console.error("PUT /api/tasks error:", err.message);
    res.status(500).json({ error: "Failed to update task" });
  }
});

// DELETE /api/tasks/:id — Delete a task
app.delete("/api/tasks/:id", async (req, res) => {
  const { id } = req.params;

  try {
    const result = await pool.query(
      "DELETE FROM tasks WHERE id = $1 RETURNING *",
      [id]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: "Task not found" });
    }

    await clearCache("tasks:*");
    res.json({ message: "Task deleted", data: result.rows[0] });
  } catch (err) {
    console.error("DELETE /api/tasks error:", err.message);
    res.status(500).json({ error: "Failed to delete task" });
  }
});

// GET /api/stats — App statistics (demonstrates Redis caching value)
app.get("/api/stats", async (req, res) => {
  try {
    const cached = await getCached("stats");
    if (cached) {
      return res.json({ source: "cache", data: cached });
    }

    const totalResult = await pool.query("SELECT COUNT(*) FROM tasks");
    const pendingResult = await pool.query(
      "SELECT COUNT(*) FROM tasks WHERE status = 'pending'"
    );
    const completedResult = await pool.query(
      "SELECT COUNT(*) FROM tasks WHERE status = 'completed'"
    );

    const stats = {
      total: parseInt(totalResult.rows[0].count),
      pending: parseInt(pendingResult.rows[0].count),
      completed: parseInt(completedResult.rows[0].count),
      hostname: require("os").hostname(),
    };

    await setCache("stats", stats, 10);
    res.json({ source: "database", data: stats });
  } catch (err) {
    console.error("GET /api/stats error:", err.message);
    res.status(500).json({ error: "Failed to fetch stats" });
  }
});

// ── Start Server ──
app.listen(PORT, () => {
  console.log(`Backend API running on port ${PORT}`);
  initDB();
});

module.exports = app;
