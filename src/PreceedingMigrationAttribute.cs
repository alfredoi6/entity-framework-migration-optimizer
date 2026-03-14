namespace YourApp.Data.DesignTime;

/// <summary>
/// Identifies the preceding migration in the migration chain.
/// Automatically added by <see cref="CustomCSharpMigrationsGenerator"/> to help
/// detect migration conflicts from parallel branch merges.
/// </summary>
[AttributeUsage(AttributeTargets.Class, AllowMultiple = false, Inherited = false)]
public sealed class PreceedingMigrationAttribute : Attribute
{
    public string MigrationId { get; }

    public PreceedingMigrationAttribute(string migrationId)
    {
        MigrationId = migrationId ?? throw new ArgumentNullException(nameof(migrationId));
    }
}
