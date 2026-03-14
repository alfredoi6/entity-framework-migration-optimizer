using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Migrations.Design;

namespace YourApp.Data.DesignTime;

/// <summary>
/// Custom migration code generator that adds <see cref="PreceedingMigrationAttribute"/>
/// and <see cref="SnapshotGeneratedFromMigrationAttribute"/> to generated migrations and snapshots,
/// enabling easier detection of branch merge conflicts.
/// </summary>
public class CustomCSharpMigrationsGenerator : CSharpMigrationsGenerator
{
    private readonly IMigrationsAssembly _migrationsAssembly;
    private string? _currentMigrationId;

    public CustomCSharpMigrationsGenerator(
        MigrationsCodeGeneratorDependencies dependencies,
        CSharpMigrationsGeneratorDependencies csharpDependencies,
        IMigrationsAssembly migrationsAssembly)
        : base(dependencies, csharpDependencies)
    {
        _migrationsAssembly = migrationsAssembly;
    }

    public override string GenerateMetadata(
        string migrationNamespace,
        Type contextType,
        string migrationName,
        string migrationId,
        IModel targetModel)
    {
        _currentMigrationId = migrationId;
        var code = base.GenerateMetadata(
            migrationNamespace, contextType, migrationName, migrationId, targetModel);

        var precedingMigrationId = _migrationsAssembly.Migrations
            .Select(m => m.Key)
            .OrderBy(id => id)
            .LastOrDefault();

        if (precedingMigrationId != null)
        {
            var pattern = new Regex(@"(\[Migration\(""[^""]+"")\)\]");
            var replacement = $"$1)]\r\n    [PreceedingMigration(\"{precedingMigrationId}\")]";
            code = pattern.Replace(code, replacement, 1);
            code = EnsureDesignTimeUsing(code);
        }

        return code;
    }

    public override string GenerateSnapshot(
        string modelSnapshotNamespace,
        Type contextType,
        string modelSnapshotName,
        IModel model)
    {
        var code = base.GenerateSnapshot(
            modelSnapshotNamespace, contextType, modelSnapshotName, model);

        var migrationId = _currentMigrationId ?? GetMigrationIdAfterRemovingLatest();

        if (migrationId != null)
        {
            var pattern = new Regex(@"(\[DbContext\(typeof\([^)]+\)\)\])");
            var replacement = $"$1\r\n    [SnapshotGeneratedFromMigration(\"{migrationId}\")]";
            code = pattern.Replace(code, replacement, 1);
            code = EnsureDesignTimeUsing(code);
        }

        return code;
    }

    private static string EnsureDesignTimeUsing(string code)
    {
        const string usingLine = "using YourApp.Data.DesignTime;";
        if (code.Contains(usingLine))
            return code;

        var namespaceIndex = code.IndexOf("namespace ");
        var searchArea = namespaceIndex > 0 ? code[..namespaceIndex] : code;
        var lastUsingIndex = searchArea.LastIndexOf("using ");
        if (lastUsingIndex < 0)
            return code;

        var endOfLine = code.IndexOf('\n', lastUsingIndex);
        if (endOfLine < 0)
            return code;

        var lineEnding = endOfLine > 0 && code[endOfLine - 1] == '\r' ? "\r\n" : "\n";
        return code.Insert(endOfLine + 1, usingLine + lineEnding);
    }

    private string? GetMigrationIdAfterRemovingLatest()
    {
        var sorted = _migrationsAssembly.Migrations
            .Select(m => m.Key)
            .OrderBy(id => id)
            .ToList();

        return sorted.Count >= 2 ? sorted[sorted.Count - 2] : null;
    }
}
