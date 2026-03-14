# EF Migration Optimizer

**Your EF Core builds are compiling 10x more code than they need to.**

Every `Designer.cs` file contains a **full copy of your entire model**. With 30 migrations and 75 entities, that's 200,000+ lines of duplicated code — compiled on every single build. This tool eliminates that overhead in seconds.

---

## The Story

On every EF Core project I've worked on, builds gradually got slower as the database model grew. I always assumed it was just the cost of a larger codebase.

Then I did a file diff on two `Designer.cs` files. They were nearly identical -- each one contained a full copy of the entire database model. Every migration had its own copy. The same 10,000+ lines, duplicated dozens of times, all compiled on every build.

If I had known how EF Core internals worked -- or just opened those files sooner -- I could have fixed this years ago. Now every team I work on doesn't get slower as the database evolves.

---

## The Problem

When you run `dotnet ef migrations add`, EF Core generates three things:

1. **`{timestamp}_MyMigration.cs`** — the `Up()` / `Down()` schema diff (small, useful)
2. **`{timestamp}_MyMigration.Designer.cs`** — a **full snapshot of your entire model** at that point in time (massive, mostly useless)
3. **`DbContextModelSnapshot.cs`** — the current model state (one file, necessary)

EF Core only needs the **latest** snapshot to generate new migrations. But it keeps every historical Designer.cs file, each one a near-complete duplicate. Here's what that looks like over time:

```
Migration  1:  Designer.cs =  2,000 lines  (model at that point)
Migration  5:  Designer.cs =  4,000 lines  (model grew)
Migration 10:  Designer.cs =  6,500 lines  (more entities)
Migration 20:  Designer.cs = 10,000 lines  (still growing)
Migration 30:  Designer.cs = 16,000 lines  (full model copy)
                                    ──────
Total Designer.cs lines:           ~230,000  ← compiled EVERY build
```

### Real Numbers from a Production Project

| Component | Files | Lines | % of Total |
|---|---|---|---|
| Model Snapshot | 1 | ~10,000 | 4% |
| Designer.cs files | 34 | ~210,000 | **89%** |
| Migration .cs files | 34 | ~15,000 | 7% |
| **Total** | **69** | **~235,000** | 100% |

**89% of all migration code is redundant duplication.** It exists only because EF Core's default generator writes a full model snapshot into every Designer.cs file.

### Why This Hurts

- **Build times scale with migration count**, not codebase complexity
- **Every downstream project waits** — if your data layer is on the dependency chain, everything blocks on compiling 200K+ lines of generated code
- **CI/CD pipelines suffer** — clean builds compile all of it every time
- **IDE performance degrades** — indexing, IntelliSense, and code analysis crawl through hundreds of thousands of duplicate lines
- **Git diffs become unreadable** — every migration PR includes a 10,000+ line Designer.cs that reviewers learn to ignore

---

## The Solution

**EF Migration Optimizer** is a PowerShell toolkit that replaces the body of historical Designer.cs files with empty stubs — keeping the metadata EF Core needs while eliminating the duplicated model code.

### Before (16,375 lines)

```csharp
[DbContext(typeof(AppDbContext))]
[Migration("20260310234950_AddInvoiceItems")]
partial class AddInvoiceItems
{
    protected override void BuildTargetModel(ModelBuilder modelBuilder)
    {
        // 16,000+ lines of model configuration
        modelBuilder.HasAnnotation("ProductVersion", "9.0.0");
        modelBuilder.Entity("App.Domain.User", b =>
        {
            b.Property<int>("Id")...
            b.Property<string>("Email")...
            // ... every entity, every property, every relationship
            // ... for your ENTIRE database model
            // ... duplicated in EVERY Designer.cs file
        });
    }
}
```

### After (25 lines)

```csharp
[DbContext(typeof(AppDbContext))]
[Migration("20260310234950_AddInvoiceItems")]
partial class AddInvoiceItems
{
    protected override void BuildTargetModel(ModelBuilder modelBuilder)
    {
    }
}
```

**Same migration. Same metadata. Zero overhead.**

---

## Quick Start

### 1. Copy the script into your migrations folder

Place `ef-migration-optimizer.ps1` in the same directory as your `*.Designer.cs` files:

```
src/YourApp.Data/Migrations/
  ├── 20240101_Initial.cs
  ├── 20240101_Initial.Designer.cs          ← these get slimmed
  ├── 20240215_AddUsers.cs
  ├── 20240215_AddUsers.Designer.cs         ← these get slimmed
  ├── 20240301_AddOrders.cs
  ├── 20240301_AddOrders.Designer.cs        ← these get slimmed
  ├── AppDbContextModelSnapshot.cs
  └── ef-migration-optimizer.ps1                  ← put it here
```

### 2. Check the current state

```powershell
.\ef-migration-optimizer.ps1 status
```

```
Migration Designer.cs Status (34 migrations)

Migration                                                    Active     .generated .slim
----------------------------------------------------------   --------   --------   --------
20240101120000_Initial                                       full       -          -
20240215143000_AddUsers                                      full       -          -
20240301090000_AddOrders                                     full       -          -
...
```

### 3. Slim all Designer.cs files

```powershell
.\ef-migration-optimizer.ps1 slim-all
```

```
Slimming 34 migrations:
  20240101120000_Initial - 6432 -> 25 lines
  20240215143000_AddUsers - 8901 -> 25 lines
  20240301090000_AddOrders - 10244 -> 25 lines
  ...

Done.
```

That's it. Your next build compiles ~25 lines per migration instead of ~10,000+.

### 4. Restore when needed

Need to run `dotnet ef migrations remove`? Restore the last migration first:

```powershell
.\ef-migration-optimizer.ps1 restore-last 1
```

---

## How It Works

### File Convention

The script manages three versions of each Designer.cs file:

| File | Purpose |
|---|---|
| `*.Designer.cs` | Active compiled file (either full or slim) |
| `*.Designer.cs.generated` | Backup of the full original |
| `*.Designer.cs.slim` | Backup of the slim version |

When you **slim** a migration, the script:

1. Backs up the full Designer.cs as `*.Designer.cs.generated`
2. Generates a slim version with an empty `BuildTargetModel` body
3. Saves the slim version as both `*.Designer.cs.slim` and the active `*.Designer.cs`

When you **restore** a migration, it copies the `.generated` backup back to the active `*.Designer.cs`.

### Why This Is Safe

EF Core uses `BuildTargetModel` in Designer.cs files for exactly **one purpose**: comparing the model state between migrations when generating a new migration. It only ever reads the **latest** migration's Designer.cs for this comparison. Historical Designer.cs files are metadata stubs — EF Core reads the `[Migration]` attribute and class name, but never calls `BuildTargetModel` on old migrations during normal operations.

**What works with slimmed designers:**
- `dotnet ef database update` (applies migrations using `Up()`/`Down()`, not `BuildTargetModel`)
- `dotnet ef migrations list` (reads `[Migration]` attributes only)
- `dotnet ef migrations add` (compares against the **snapshot**, not old designers)
- Application startup and runtime queries
- All normal development workflows

**What requires restoring:**
- `dotnet ef migrations remove` (needs the latest Designer.cs to regenerate the snapshot)

For a deeper look at how EF Core uses Designer.cs files internally, see [How EF Core Uses Designer Files](HOW-EF-CORE-USES-DESIGNER-FILES.md).

---

## Commands Reference

All commands are run from your migrations folder.

| Command | Description | Example |
|---|---|---|
| `status` | Show slim/full state of all designers | `.\ef-migration-optimizer.ps1 status` |
| `slim <name>` | Slim a single migration (partial name match) | `.\ef-migration-optimizer.ps1 slim AddUsers` |
| `slim-all` | Slim all migration designers | `.\ef-migration-optimizer.ps1 slim-all` |
| `restore <name>` | Restore a single migration to full | `.\ef-migration-optimizer.ps1 restore AddUsers` |
| `restore-last <N>` | Restore the last N migrations | `.\ef-migration-optimizer.ps1 restore-last 3` |
| `sync-snapshot <name>` | Sync snapshot from a migration's designer | `.\ef-migration-optimizer.ps1 sync-snapshot AddUsers` |

### The `sync-snapshot` Command

This is the power move for teams. When you merge branches that both contain migrations, the `DbContextModelSnapshot.cs` can get out of sync. Instead of manually resolving a 10,000+ line merge conflict, just run:

```powershell
.\ef-migration-optimizer.ps1 sync-snapshot <LatestMigrationName>
```

It extracts the model body from the specified migration's Designer.cs (using the `.generated` backup if slimmed) and replaces the snapshot's body with it. Merge conflicts in the snapshot become a one-liner to resolve.

---

## Advanced: Custom Migration Generator

For teams that want deeper integration, you can extend EF Core's code generator to automatically track migration lineage. This makes branch merges safer by recording which migration preceded each new one and which migration the snapshot was generated for.

The `src/` directory contains three drop-in C# classes:

| File | Purpose |
|---|---|
| [`PreceedingMigrationAttribute.cs`](src/PreceedingMigrationAttribute.cs) | Attribute that records which migration preceded the current one |
| [`SnapshotGeneratedFromMigrationAttribute.cs`](src/SnapshotGeneratedFromMigrationAttribute.cs) | Attribute that records which migration the snapshot was generated from |
| [`CustomCSharpMigrationsGenerator.cs`](src/CustomCSharpMigrationsGenerator.cs) | Overrides EF Core's code generator to add both attributes automatically |

Copy these into your project (updating the namespace from `YourApp.Data.DesignTime` to match yours), then register the generator:

```csharp
services.AddDbContext<AppDbContext>(options =>
{
    options.UseNpgsql(connectionString); // or UseSqlServer, UseSqlite, etc.
    options.ReplaceService<IMigrationsCodeGenerator, CustomCSharpMigrationsGenerator>();
});
```

This gives you two things:
1. **`[PreceedingMigration]`** on every migration -- instantly detect when two branches created migrations from the same parent (merge conflict)
2. **`[SnapshotGeneratedFromMigration]`** on the snapshot -- know exactly which migration the snapshot corresponds to

---

## Team Workflow

Here's the recommended workflow for teams using this tool:

### Adding a New Migration

```powershell
# 1. Slim all existing designers (fast, idempotent)
.\ef-migration-optimizer.ps1 slim-all

# 2. Restore the last migration (needed for EF Core to diff correctly)
.\ef-migration-optimizer.ps1 restore-last 1

# 3. Create your migration normally
dotnet ef migrations add AddInvoiceItems --project src/YourApp.Data --startup-project src/YourApp.Data

# 4. Slim everything again (including the new migration)
.\ef-migration-optimizer.ps1 slim-all

# 5. Commit — your PR has a ~25 line Designer.cs instead of 10,000+
```

### Resolving Migration Merge Conflicts

```powershell
# 1. Accept incoming changes from the target branch for all migration files
git checkout --theirs src/YourApp.Data/Migrations/

# 2. Slim all, restore last, sync snapshot
.\ef-migration-optimizer.ps1 slim-all
.\ef-migration-optimizer.ps1 restore-last 1
.\ef-migration-optimizer.ps1 sync-snapshot <LatestMigrationName>

# 3. Create your migration again — it will diff correctly
dotnet ef migrations add AddInvoiceItems --project src/YourApp.Data --startup-project src/YourApp.Data
```

No more 10,000-line merge conflicts in Designer.cs files. No more broken snapshots. No more "which version do I keep?"

---

## FAQ

### Does this break `dotnet ef database update`?

No. `database update` applies migrations by calling `Up()` and `Down()` methods in the migration `.cs` files. It never calls `BuildTargetModel` on historical Designer.cs files.

### Does this break `dotnet ef migrations add`?

No. When generating a new migration, EF Core compares your current DbContext model against the `DbContextModelSnapshot.cs` — not against old Designer.cs files. The snapshot is always kept at full fidelity.

### Does this break `dotnet ef migrations remove`?

Only if the **latest** migration is slimmed. The `remove` command needs the latest Designer.cs to regenerate the snapshot. That's why the workflow always restores the last migration before working with EF tooling. After removing, just slim again.

### Can I commit the `.generated` and `.slim` backup files?

Yes. They're useful for the team so anyone can restore without re-running EF tooling. Alternatively, add `*.Designer.cs.generated` and `*.Designer.cs.slim` to `.gitignore` if you prefer a cleaner repo — the script will recreate them as needed.

### Does this work with SQL Server / SQLite / MySQL?

Yes. The Designer.cs format is identical across all EF Core database providers. The script operates purely on the C# file structure.

### How much build time does this actually save?

It depends on your model size and migration count. In a production project with 75 entities and 34 migrations, slimming reduced the compiled migration code from **~235,000 lines to ~16,000 lines** — an **93% reduction**. Build times for the data layer dropped proportionally.

### Does this work with .NET 6 / 7 / 8 / 9?

Yes. The Designer.cs format has been stable since EF Core 2.0. The script works with any version.

---

## Compatibility

| EF Core Version | Supported |
|---|---|
| 2.x | Yes |
| 3.x | Yes |
| 5.x | Yes |
| 6.x | Yes |
| 7.x | Yes |
| 8.x | Yes |
| 9.x | Yes |

| Database Provider | Supported |
|---|---|
| SQL Server | Yes |
| PostgreSQL (Npgsql) | Yes |
| SQLite | Yes |
| MySQL / MariaDB | Yes |
| Any EF Core provider | Yes |

---

## Contributing

Found a bug? Have an improvement? PRs are welcome.

1. Fork the repo
2. Create a feature branch
3. Submit a PR with a clear description

---

## License

MIT License. Use it, share it, optimize your builds.

---

**If this saved your team time, give it a star.** Every .NET team with more than a handful of EF Core migrations is compiling thousands of lines of duplicated code on every build — and most of them don't know it yet. Share this with them.
