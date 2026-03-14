# How EF Core Uses Designer.cs Files

A technical look at what `BuildTargetModel` actually does, when EF Core calls it, and why it's safe to empty it on historical migrations.

---

## What Is BuildTargetModel?

Every time you run `dotnet ef migrations add`, EF Core generates a `Designer.cs` file alongside your migration. Inside it is a method called `BuildTargetModel(ModelBuilder modelBuilder)` that contains a complete, code-generated representation of your entire database model **as it existed at the time that migration was created**.

This includes every entity, every property, every relationship, every index, and every annotation -- for your entire DbContext. In a project with 75 entities, this method alone can be 10,000--16,000 lines of code.

Here's a simplified example of what it looks like:

```csharp
[DbContext(typeof(AppDbContext))]
[Migration("20260215143000_AddUsers")]
partial class AddUsers
{
    protected override void BuildTargetModel(ModelBuilder modelBuilder)
    {
        #pragma warning disable 612, 618
        modelBuilder.HasAnnotation("ProductVersion", "9.0.0");
        modelBuilder.HasAnnotation("Relational:MaxIdentifierLength", 63);
        NpgsqlModelBuilderExtensions.UseIdentityByDefaultColumns(modelBuilder);

        modelBuilder.Entity("App.Domain.User", b =>
        {
            b.Property<int>("Id")
                .ValueGeneratedOnAdd()
                .HasColumnType("integer");
            b.Property<string>("Email")
                .IsRequired()
                .HasMaxLength(256)
                .HasColumnType("character varying(256)");
            // ... hundreds more properties
            b.HasKey("Id");
            b.ToTable("users");
        });

        // ... every other entity in your entire model
        // ... repeated in EVERY Designer.cs file
        #pragma warning restore 612, 618
    }
}
```

The key thing to understand: this is **not** the migration diff. The `Up()` and `Down()` methods in the companion `.cs` file contain the actual schema changes. `BuildTargetModel` is a snapshot of the full model state at that point in time.

---

## When Does EF Core Actually Call BuildTargetModel?

There are four contexts where `BuildTargetModel` could theoretically be relevant. Only one of them actually matters.

### 1. Migration Removal (`dotnet ef migrations remove`)

**This is the only scenario where BuildTargetModel is actively called.**

When you remove the latest migration, EF Core needs to regenerate `DbContextModelSnapshot.cs` to reflect the model state *before* that migration existed. To do this, it reads `BuildTargetModel` from the **previous** migration's Designer.cs -- the one that will become the new "latest" after removal.

The flow:

1. You run `dotnet ef migrations remove`
2. EF Core identifies the latest migration and the one before it
3. It calls `BuildTargetModel` on the **previous** migration's Designer.cs
4. It uses that model to regenerate `DbContextModelSnapshot.cs`
5. It deletes the latest migration's `.cs` and `Designer.cs` files

This means:
- Only the **second-to-last** Designer.cs is read during removal
- All other historical Designer.cs files are never touched
- If you always restore the last migration before removing (as the optimizer workflow recommends), this works perfectly

### 2. Migration Application (`dotnet ef database update` / `Database.Migrate()`)

**BuildTargetModel is NOT called.**

When EF Core applies migrations to a database, it executes the `Up()` method for each pending migration. When rolling back, it executes `Down()`. The actual schema changes are entirely contained in these methods.

EF Core does read the `[Migration]` attribute from Designer.cs to identify the migration and its ordering, but it never calls `BuildTargetModel` during application. The model metadata is available in memory but is not used to generate or execute SQL.

### 3. Migration Scaffolding (`dotnet ef migrations add`)

**BuildTargetModel is NOT called on historical Designer.cs files.**

When generating a new migration, EF Core needs two things:
1. The **current model** -- built live from your DbContext, entity configurations, and `OnModelCreating`
2. The **previous model** -- read from `DbContextModelSnapshot.cs`

It diffs these two models to produce the `Up()` and `Down()` methods for the new migration. Historical Designer.cs files are not part of this process. The snapshot file is the sole "before" picture.

This is why slimming old Designer.cs files has zero effect on `migrations add`.

### 4. Historical Record / Debugging

**Not functionally required by EF Core.**

The full model in each Designer.cs serves as a point-in-time record of what the model looked like when that migration was created. This can be useful for:
- Understanding what changed between two migrations (diff two Designer.cs files)
- Debugging unexpected migration output
- Auditing schema evolution over time

But EF Core itself never reads these for any operational purpose beyond the removal scenario described above.

---

## Summary

| Scenario | Calls BuildTargetModel? | Which Designer.cs? |
|---|---|---|
| `dotnet ef database update` | No | None |
| `Database.Migrate()` at runtime | No | None |
| `dotnet ef migrations add` | No | None (uses snapshot) |
| `dotnet ef migrations list` | No | None (reads attributes only) |
| `dotnet ef migrations remove` | **Yes** | Previous migration only |
| `dotnet ef migrations script` | No | None |

**The conclusion:** for every migration except the one that would become "latest" after a removal, `BuildTargetModel` is dead code. It compiles on every build, contributes to IDE indexing overhead, bloats git diffs, and serves no functional purpose. Emptying it is safe.

---

## Further Reading

- [EF Core Migrations Overview](https://learn.microsoft.com/en-us/ef/core/managing-schemas/migrations/) -- official docs
- [EF Core source: MigrationsScaffolder.cs](https://github.com/dotnet/efcore/blob/main/src/EFCore.Design/Migrations/Design/MigrationsScaffolder.cs) -- where `migrations add` and `migrations remove` are implemented
- [EF Core source: Migrator.cs](https://github.com/dotnet/efcore/blob/main/src/EFCore.Relational/Migrations/Internal/Migrator.cs) -- where `database update` is implemented
