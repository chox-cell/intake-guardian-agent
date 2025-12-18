import sqlite3 from "sqlite3";
import { Store } from "./store.js";
import { AuditEvent, WorkItem, Status } from "../types/contracts.js";

function run(db: sqlite3.Database, sql: string, params: any[] = []) {
  return new Promise<void>((resolve, reject) => {
    db.run(sql, params, (err) => (err ? reject(err) : resolve()));
  });
}
function get<T>(db: sqlite3.Database, sql: string, params: any[] = []) {
  return new Promise<T | undefined>((resolve, reject) => {
    db.get(sql, params, (err, row) => (err ? reject(err) : resolve(row as T)));
  });
}
function all<T>(db: sqlite3.Database, sql: string, params: any[] = []) {
  return new Promise<T[]>((resolve, reject) => {
    db.all(sql, params, (err, rows) => (err ? reject(err) : resolve(rows as T[])));
  });
}

export class SqliteStore implements Store {
  private db: sqlite3.Database;

  constructor(private dbPath: string) {
    this.db = new sqlite3.Database(dbPath);
  }

  async init(): Promise<void> {
    await run(this.db, `pragma journal_mode = wal;`);
    await run(this.db, `
      create table if not exists workitems (
        id text primary key,
        tenantId text not null,
        source text not null,
        sender text not null,
        subject text,
        rawBody text not null,
        normalizedBody text not null,
        category text not null,
        priority text not null,
        status text not null,
        ownerId text,
        slaSeconds integer not null,
        dueAt text,
        tagsJson text not null,
        fingerprint text not null,
        presetId text not null,
        createdAt text not null,
        updatedAt text not null
      );
    `);
    await run(this.db, `create index if not exists idx_workitems_tenant_status on workitems(tenantId, status);`);
    await run(this.db, `create index if not exists idx_workitems_tenant_fp on workitems(tenantId, fingerprint);`);
    await run(this.db, `create index if not exists idx_workitems_tenant_updated on workitems(tenantId, updatedAt);`);

    await run(this.db, `
      create table if not exists audit_events (
        id text primary key,
        tenantId text not null,
        workItemId text not null,
        type text not null,
        actor text not null,
        payloadJson text not null,
        at text not null
      );
    `);
    await run(this.db, `create index if not exists idx_audit_tenant_workitem on audit_events(tenantId, workItemId, at);`);
  }

  async createWorkItem(item: WorkItem): Promise<void> {
    await run(this.db, `
      insert into workitems (
        id, tenantId, source, sender, subject, rawBody, normalizedBody,
        category, priority, status, ownerId, slaSeconds, dueAt, tagsJson,
        fingerprint, presetId, createdAt, updatedAt
      ) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `, [
      item.id, item.tenantId, item.source, item.sender, item.subject ?? null,
      item.rawBody, item.normalizedBody,
      item.category, item.priority, item.status, item.ownerId ?? null,
      item.slaSeconds, item.dueAt ?? null, JSON.stringify(item.tags ?? []),
      item.fingerprint, item.presetId, item.createdAt, item.updatedAt
    ]);
  }

  async getWorkItem(tenantId: string, id: string): Promise<WorkItem | null> {
    const row = await get<any>(this.db, `select * from workitems where tenantId=? and id=?`, [tenantId, id]);
    return row ? this.rowToWorkItem(row) : null;
  }

  async listWorkItems(tenantId: string, q: { status?: Status; limit?: number; offset?: number; search?: string; }): Promise<WorkItem[]> {
    const limit = Math.min(q.limit ?? 50, 200);
    const offset = q.offset ?? 0;

    const where: string[] = [`tenantId = ?`];
    const params: any[] = [tenantId];

    if (q.status) { where.push(`status = ?`); params.push(q.status); }
    if (q.search) { where.push(`(normalizedBody like ? or sender like ? or subject like ?)`); params.push(`%${q.search}%`, `%${q.search}%`, `%${q.search}%`); }

    const sql = `
      select * from workitems
      where ${where.join(" and ")}
      order by updatedAt desc
      limit ? offset ?
    `;
    params.push(limit, offset);
    const rows = await all<any>(this.db, sql, params);
    return rows.map(r => this.rowToWorkItem(r));
  }

  async findByFingerprint(tenantId: string, fingerprint: string, windowSeconds: number): Promise<WorkItem | null> {
    // Window is enforced by createdAt comparison.
    const since = new Date(Date.now() - windowSeconds * 1000).toISOString();
    const row = await get<any>(this.db, `
      select * from workitems
      where tenantId=? and fingerprint=? and createdAt >= ?
      order by createdAt desc
      limit 1
    `, [tenantId, fingerprint, since]);
    return row ? this.rowToWorkItem(row) : null;
  }

  async updateStatus(tenantId: string, id: string, next: Status): Promise<void> {
    const now = new Date().toISOString();
    await run(this.db, `update workitems set status=?, updatedAt=? where tenantId=? and id=?`, [next, now, tenantId, id]);
  }

  async assignOwner(tenantId: string, id: string, ownerId: string | null): Promise<void> {
    const now = new Date().toISOString();
    await run(this.db, `update workitems set ownerId=?, updatedAt=? where tenantId=? and id=?`, [ownerId, now, tenantId, id]);
  }

  async appendAudit(ev: AuditEvent): Promise<void> {
    await run(this.db, `
      insert into audit_events (id, tenantId, workItemId, type, actor, payloadJson, at)
      values (?,?,?,?,?,?,?)
    `, [ev.id, ev.tenantId, ev.workItemId, ev.type, ev.actor, JSON.stringify(ev.payload ?? {}), ev.at]);
  }

  async listAudit(tenantId: string, workItemId: string, limit: number = 200): Promise<AuditEvent[]> {
    const rows = await all<any>(this.db, `
      select * from audit_events
      where tenantId=? and workItemId=?
      order by at asc
      limit ?
    `, [tenantId, workItemId, Math.min(limit, 1000)]);
    return rows.map(r => ({
      id: r.id,
      tenantId: r.tenantId,
      workItemId: r.workItemId,
      type: r.type,
      actor: r.actor,
      payload: JSON.parse(r.payloadJson || "{}"),
      at: r.at
    }));
  }

  private rowToWorkItem(r: any): WorkItem {
    return {
      id: r.id,
      tenantId: r.tenantId,
      source: r.source,
      sender: r.sender,
      subject: r.subject ?? undefined,
      rawBody: r.rawBody,
      normalizedBody: r.normalizedBody,
      category: r.category,
      priority: r.priority,
      status: r.status,
      ownerId: r.ownerId ?? undefined,
      slaSeconds: r.slaSeconds,
      dueAt: r.dueAt ?? undefined,
      tags: JSON.parse(r.tagsJson || "[]"),
      fingerprint: r.fingerprint,
      presetId: r.presetId,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt
    };
  }
}
