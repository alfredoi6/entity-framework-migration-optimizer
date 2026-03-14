namespace YourApp.Data.DesignTime;

/// <summary>
/// Identifies which migration the model snapshot was generated from.
/// Automatically added by <see cref="CustomCSharpMigrationsGenerator"/> to help
/// detect snapshot drift after parallel branch merges.
/// </summary>
[AttributeUsage(AttributeTargets.Class, AllowMultiple = false, Inherited = false)]
public sealed class SnapshotGeneratedFromMigrationAttribute : Attribute
{
    public string MigrationId { get; }

    public SnapshotGeneratedFromMigrationAttribute(string migrationId)
    {
        MigrationId = migrationId ?? throw new ArgumentNullException(nameof(migrationId));
    }
}
