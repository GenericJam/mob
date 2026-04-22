# Data & Persistence

Every generated Mob app ships with two persistence layers ready to use. They serve different purposes and work well together.

| | `Mob.State` | Ecto Repo |
|---|---|---|
| Backed by | `:dets` (OTP stdlib) | SQLite3 via `ecto_sqlite3` |
| Best for | App preferences, UI state | User records, structured data |
| API | `get/put/delete` | Schemas, queries, migrations |
| Setup | None — auto-started | `mix ecto.migrate` |
| Capacity | O(dozens) of keys | Millions of rows |

## Mob.State — app preferences

`Mob.State` is a key-value store for small amounts of app state that should survive kills and restarts. It is backed by [`:dets`](https://www.erlang.org/doc/apps/stdlib/dets.html) — Erlang's disk-based term storage from the OTP stdlib. No extra dependencies, no migrations, no setup. It is started automatically by the framework before `on_start/0` runs.

```elixir
# Persist any Elixir term
Mob.State.put(:theme, :citrus)
Mob.State.put(:onboarded, true)
Mob.State.put(:last_tab, :settings)

# Read back on next launch — returns default if not yet set
Mob.State.get(:theme, :obsidian)   #=> :citrus
Mob.State.get(:missing, 0)         #=> 0

# Remove a key
Mob.State.delete(:theme)
```

Writes call `:dets.sync/1` before returning, so data is on disk before the function returns — safe against `SIGKILL`.

Good candidates for `Mob.State`: selected theme, onboarding completion flag, last-opened tab, cached user ID, notification preferences. If you find yourself storing hundreds of keys or wanting to query across them, move that data to Ecto.

See `Mob.State` for the full API reference.

## Ecto — structured data

Every generated app includes [Ecto](https://hexdocs.pm/ecto) and [ecto_sqlite3](https://hexdocs.pm/ecto_sqlite3), giving you the full Ecto experience on-device backed by SQLite. If you have used Ecto with PostgreSQL in Phoenix, the API is identical for day-to-day use.

Your app's Repo is generated at `lib/my_app/repo.ex`. It is started in `on_start/0` and reads `MOB_DATA_DIR` (set by the native launcher) to place the database file in the platform's correct persistent storage directory — `getFilesDir()` on Android, `NSDocumentDirectory` on iOS.

### Defining a schema

```elixir
defmodule MyApp.Note do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field :title,   :string
    field :body,    :string
    field :pinned,  :boolean, default: false
    timestamps()
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :body, :pinned])
    |> validate_required([:title])
  end
end
```

### Writing migrations

```bash
mix ecto.gen.migration create_notes
```

```elixir
# priv/repo/migrations/20260422000000_create_notes.exs
defmodule MyApp.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :title,  :string,  null: false
      add :body,   :text
      add :pinned, :boolean, default: false
      timestamps()
    end
  end
end
```

```bash
mix ecto.migrate
```

### Querying from a screen

```elixir
import Ecto.Query

def mount(_params, _session, socket) do
  notes = MyApp.Repo.all(from n in MyApp.Note, order_by: [desc: n.inserted_at])
  {:ok, Mob.Socket.assign(socket, :notes, notes)}
end

def handle_info({:tap, :pin}, socket) do
  note = hd(socket.assigns.notes)
  {:ok, _} = MyApp.Repo.update(MyApp.Note.changeset(note, %{pinned: true}))
  {:noreply, socket}
end
```

### SQLite differences from PostgreSQL

For most queries you will notice nothing different. A few things to be aware of:

- **`pool_size: 1`** — SQLite supports only one writer at a time. The Repo is pre-configured with a single connection; no tuning needed.
- **Limited `ALTER TABLE`** — SQLite cannot drop or rename columns in older versions. Write migrations that add columns or recreate tables instead.
- **No arrays or JSONB indexes** — use `string` fields with `Jason` encode/decode if you need nested data, or normalise into a separate table.
- **UUIDs stored as binary** — use `:binary_id` primary keys as normal; the adapter handles encoding transparently.

For a full reference see the [ecto_sqlite3 documentation](https://hexdocs.pm/ecto_sqlite3) and the [Ecto query API](https://hexdocs.pm/ecto/Ecto.Query.html).

## Running migrations on-device

The generated `on_start/0` starts the Repo but does not auto-run migrations. For most apps, running `mix ecto.migrate` in dev is sufficient — ship a database schema that matches what the app expects. If your app needs to migrate an existing on-device database (e.g. after an app store update), add a migration step before the Repo starts:

```elixir
def on_start do
  Application.ensure_all_started(:ecto_sqlite3)
  {:ok, _} = MyApp.Repo.start_link()
  Ecto.Migrator.with_repo(MyApp.Repo, &Ecto.Migrator.run(&1, :up, all: true))
  Mob.Screen.start_root(MyApp.HomeScreen)
end
```

The migration modules are compiled into your app's `.beam` files and copied to the device by the build scripts, so `Ecto.Migrator` finds them at the correct path via `:code.priv_dir/1`.
