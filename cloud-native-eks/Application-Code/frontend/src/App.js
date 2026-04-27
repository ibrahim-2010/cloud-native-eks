import React, { useState, useEffect, useCallback } from "react";
import "./App.css";

const API_URL = process.env.REACT_APP_BACKEND_URL || "/api";

function App() {
  const [tasks, setTasks] = useState([]);
  const [stats, setStats] = useState(null);
  const [health, setHealth] = useState(null);
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const fetchTasks = useCallback(async () => {
    try {
      const res = await fetch(`${API_URL}/tasks`);
      const data = await res.json();
      setTasks(data.data || []);
      setError(null);
    } catch (err) {
      setError("Failed to connect to backend API");
    } finally {
      setLoading(false);
    }
  }, []);

  const fetchStats = useCallback(async () => {
    try {
      const res = await fetch(`${API_URL}/stats`);
      const data = await res.json();
      setStats(data.data);
    } catch {
      /* stats are non-critical */
    }
  }, []);

  const fetchHealth = useCallback(async () => {
    try {
      const res = await fetch(`${API_URL}/health`);
      const data = await res.json();
      setHealth(data);
    } catch {
      setHealth({ status: "unreachable", postgres: "unknown", redis: "unknown" });
    }
  }, []);

  useEffect(() => {
    fetchTasks();
    fetchStats();
    fetchHealth();
    const interval = setInterval(fetchHealth, 30000);
    return () => clearInterval(interval);
  }, [fetchTasks, fetchStats, fetchHealth]);

  const addTask = async (e) => {
    e.preventDefault();
    if (!title.trim()) return;
    try {
      await fetch(`${API_URL}/tasks`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title, description }),
      });
      setTitle("");
      setDescription("");
      fetchTasks();
      fetchStats();
    } catch {
      setError("Failed to create task");
    }
  };

  const updateStatus = async (id, status) => {
    try {
      await fetch(`${API_URL}/tasks/${id}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status }),
      });
      fetchTasks();
      fetchStats();
    } catch {
      setError("Failed to update task");
    }
  };

  const deleteTask = async (id) => {
    try {
      await fetch(`${API_URL}/tasks/${id}`, { method: "DELETE" });
      fetchTasks();
      fetchStats();
    } catch {
      setError("Failed to delete task");
    }
  };

  return (
    <div className="app">
      <header className="header">
        <h1>Cloud Native Task Manager</h1>
        <p className="subtitle">Deployed on AWS EKS with PostgreSQL &amp; Redis</p>
        {health && (
          <div className="health-bar">
            <span className={`status-dot ${health.status === "healthy" ? "green" : "red"}`} />
            <span>API: {health.status}</span>
            <span className={`status-dot ${health.postgres === "connected" ? "green" : "red"}`} />
            <span>PostgreSQL</span>
            <span className={`status-dot ${health.redis === "connected" ? "green" : "red"}`} />
            <span>Redis</span>
          </div>
        )}
      </header>

      {stats && (
        <div className="stats-bar">
          <div className="stat">
            <span className="stat-num">{stats.total}</span>
            <span className="stat-label">Total</span>
          </div>
          <div className="stat">
            <span className="stat-num">{stats.pending}</span>
            <span className="stat-label">Pending</span>
          </div>
          <div className="stat">
            <span className="stat-num">{stats.completed}</span>
            <span className="stat-label">Completed</span>
          </div>
          <div className="stat">
            <span className="stat-num hostname">{stats.hostname}</span>
            <span className="stat-label">Pod</span>
          </div>
        </div>
      )}

      <div className="form-section">
        <h2>New Task</h2>
        <div className="form-row" role="form">
          <input
            type="text"
            placeholder="Task title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
          <input
            type="text"
            placeholder="Description (optional)"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
          <button onClick={addTask}>Add</button>
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="tasks-section">
        <h2>Tasks</h2>
        {loading ? (
          <p className="loading">Loading tasks...</p>
        ) : tasks.length === 0 ? (
          <p className="empty">No tasks yet. Create one above.</p>
        ) : (
          <ul className="task-list">
            {tasks.map((task) => (
              <li key={task.id} className={`task-item ${task.status}`}>
                <div className="task-info">
                  <strong>{task.title}</strong>
                  {task.description && <p>{task.description}</p>}
                  <span className="task-meta">
                    {task.status} &middot; {new Date(task.created_at).toLocaleDateString()}
                  </span>
                </div>
                <div className="task-actions">
                  {task.status === "pending" ? (
                    <button className="btn-complete" onClick={() => updateStatus(task.id, "completed")}>
                      Done
                    </button>
                  ) : (
                    <button className="btn-pending" onClick={() => updateStatus(task.id, "pending")}>
                      Reopen
                    </button>
                  )}
                  <button className="btn-delete" onClick={() => deleteTask(task.id)}>
                    Delete
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      <footer className="footer">
        <p>Cloud-Native EKS Project &middot; Ibrahim &middot; DevOps Portfolio</p>
        <p className="tech-stack">
          React &middot; Node.js &middot; PostgreSQL &middot; Redis &middot; Kubernetes &middot; Jenkins &middot; ArgoCD
        </p>
      </footer>
    </div>
  );
}

export default App;
