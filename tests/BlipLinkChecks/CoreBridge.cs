namespace MyDrive;
// This test project never reads or writes the real user profile.
internal static class CoreBridge
{
    public static string DataDir => Path.Combine(Path.GetTempPath(), "mydrive-link-preferences-check-" + Environment.ProcessId);
}
