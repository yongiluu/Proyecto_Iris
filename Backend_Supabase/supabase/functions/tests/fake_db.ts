// Base de datos simulada en memoria con la misma forma que el cliente de Supabase, solo con lo que
// usa el agente. Sirve para probar la logica de la memoria sin Docker ni un proyecto real.
// (Las reglas de seguridad de la base real se prueban aparte en Backend_Supabase/tests/test_schema.mjs.)

type Row = Record<string, unknown>;
type Result = { data: unknown; error: { message: string } | null };

export class FakeDb {
  tables: Record<string, Row[]> = {
    profiles: [], preferences: [], conversation_days: [], messages: [], daily_diaries: [],
  };
  today = "2026-11-08";
  clock = new Date("2026-11-08T12:00:00Z");
  users: Record<string, string> = {};  // token -> user id
  private ids: Record<string, number> = {};

  auth = {
    getUser: (token: string) => {
      const id = this.users[token];
      return Promise.resolve({ data: { user: id ? { id } : null }, error: null });
    },
  };

  nextId(table: string): number {
    this.ids[table] = (this.ids[table] ?? 0) + 1;
    return this.ids[table];
  }

  addUser(token: string, id: string, name = "Ana", memoryEnabled = true): void {
    this.users[token] = id;
    this.tables.profiles.push({ id, display_name: name, timezone: "America/Santiago" });
    this.tables.preferences.push({ user_id: id, memory_enabled: memoryEnabled });
  }

  tick(minutes = 1): string {
    this.clock = new Date(this.clock.getTime() + minutes * 60_000);
    return this.clock.toISOString();
  }

  from(table: string): Query {
    return new Query(this, table);
  }

  rpc(name: string, params: Row): Promise<Result> {
    if (name === "conversation_day_for") return Promise.resolve({ data: this.today, error: null });
    if (name === "search_memory") {
      // Aproximacion de la busqueda de Postgres: palabras de 4+ letras comparadas por sus primeras 5 letras.
      const normalize = (t: string) => t.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
      const stems = normalize(String(params.query)).split(/\W+/).filter((w) => w.length >= 4).map((w) => w.slice(0, 5));
      const days = Object.fromEntries(this.tables.conversation_days.map((d) => [d.id, d.day]));
      const rows = this.tables.messages
        .filter((m) => m.user_id === params.target && String(days[m.day_id as number]) >= String(params.since))
        .filter((m) => stems.some((s) => normalize(String(m.content)).includes(s)))
        .map((m) => ({ ...m, day: days[m.day_id as number] }));
      return Promise.resolve({ data: rows.slice(0, Number(params.max_results ?? 8)), error: null });
    }
    return Promise.resolve({ data: null, error: { message: `rpc desconocida ${name}` } });
  }
}

class Query implements PromiseLike<Result> {
  private filters: Array<(row: Row) => boolean> = [];
  private sort?: { column: string; ascending: boolean };
  private max?: number;
  private action: "select" | "insert" | "update" | "upsert" | "delete" = "select";
  private payload?: Row;
  private upsertOptions?: { onConflict?: string; ignoreDuplicates?: boolean };
  private returnRows = false;

  constructor(private db: FakeDb, private table: string) {}

  private get rows(): Row[] {
    return this.db.tables[this.table];
  }

  select(_columns?: string): this {
    if (this.action !== "select") this.returnRows = true;
    return this;
  }
  eq(column: string, value: unknown): this {
    this.filters.push((r) => r[column] === value);
    return this;
  }
  gt(column: string, value: unknown): this {
    this.filters.push((r) => (r[column] as number) > (value as number));
    return this;
  }
  lt(column: string, value: unknown): this {
    this.filters.push((r) => String(r[column]) < String(value));
    return this;
  }
  order(column: string, options?: { ascending?: boolean }): this {
    this.sort = { column, ascending: options?.ascending ?? true };
    return this;
  }
  limit(n: number): this {
    this.max = n;
    return this;
  }
  insert(row: Row): this {
    this.action = "insert";
    this.payload = row;
    return this;
  }
  update(changes: Row): this {
    this.action = "update";
    this.payload = changes;
    return this;
  }
  upsert(row: Row, options?: { onConflict?: string; ignoreDuplicates?: boolean }): this {
    this.action = "upsert";
    this.payload = row;
    this.upsertOptions = options;
    return this;
  }
  delete(): this {
    this.action = "delete";
    return this;
  }

  private withDefaults(row: Row): Row {
    const full: Row = { ...row };
    if (this.table === "conversation_days") {
      full.id ??= this.db.nextId(this.table);
      full.running_summary ??= "";
      full.summarized_until ??= 0;
      full.diary_written ??= false;
    }
    if (this.table === "messages") {
      full.id ??= this.db.nextId(this.table);
      full.created_at ??= this.db.tick();
    }
    return full;
  }

  private execute(): Row[] {
    const match = (r: Row) => this.filters.every((f) => f(r));
    switch (this.action) {
      case "insert": {
        const row = this.withDefaults(this.payload!);
        this.rows.push(row);
        return [row];
      }
      case "upsert": {
        const keys = (this.upsertOptions?.onConflict ?? (this.table === "daily_diaries" ? "user_id,day" : "id")).split(",");
        const existing = this.rows.find((r) => keys.every((k) => r[k] === this.payload![k]));
        if (existing) {
          if (this.upsertOptions?.ignoreDuplicates) return [];
          Object.assign(existing, this.payload);
          return [existing];
        }
        const row = this.withDefaults(this.payload!);
        this.rows.push(row);
        return [row];
      }
      case "update": {
        const hits = this.rows.filter(match);
        hits.forEach((r) => Object.assign(r, this.payload));
        return hits;
      }
      case "delete": {
        const hits = this.rows.filter(match);
        this.db.tables[this.table] = this.rows.filter((r) => !match(r));
        return hits;
      }
      default: {
        let result = this.rows.filter(match).map((r) => ({ ...r }));
        if (this.sort) {
          const { column, ascending } = this.sort;
          result.sort((a, b) => (a[column]! < b[column]! ? -1 : a[column]! > b[column]! ? 1 : 0) * (ascending ? 1 : -1));
        }
        if (this.max !== undefined) result = result.slice(0, this.max);
        return result;
      }
    }
  }

  then<T1 = Result, T2 = never>(onfulfilled?: ((value: Result) => T1 | PromiseLike<T1>) | null,
                                 onrejected?: ((reason: unknown) => T2 | PromiseLike<T2>) | null): PromiseLike<T1 | T2> {
    const rows = this.execute();
    const data = this.action === "select" || this.returnRows ? rows : null;
    return Promise.resolve({ data, error: null }).then(onfulfilled, onrejected);
  }

  single(): Promise<Result> {
    const rows = this.execute();
    return Promise.resolve(rows.length === 1 ? { data: rows[0], error: null } : { data: null, error: { message: "no hay exactamente una fila" } });
  }

  maybeSingle(): Promise<Result> {
    const rows = this.execute();
    return Promise.resolve({ data: rows[0] ?? null, error: null });
  }
}
