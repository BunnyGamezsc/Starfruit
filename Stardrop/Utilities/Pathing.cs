using System;
using System.IO;
using System.Runtime.InteropServices;

namespace Stardrop.Utilities
{
    public static class Pathing
    {
        internal static string defaultGamePath;
        internal static string defaultModPath;
        internal static string defaultHomePath;

        internal static void SetHomePath(string homePath)
        {
            defaultHomePath = Path.Combine(homePath, "Stardrop", "Data");
        }

        internal static void SetSmapiPath(string smapiPath, bool useDefaultModPath = false)
        {
            if (smapiPath is not null)
            {
                defaultGamePath = smapiPath;

                if (useDefaultModPath)
                {
                    defaultModPath = Path.Combine(smapiPath, "Mods");
                }
            }
        }

        internal static void SetModPath(string modPath)
        {
            if (modPath is not null)
            {
                defaultModPath = modPath;
            }
        }

        internal static string GetLogFolderPath()
        {
            return Path.Combine(defaultHomePath, "Logs");
        }

        internal static string GetSettingsPath()
        {
            return Path.Combine(defaultHomePath, "Settings.json");
        }

        public static string GetProfilesFolderPath()
        {
            return Path.Combine(defaultHomePath, "Profiles");
        }

        public static string GetSelectedModsFolderPath()
        {
            return Path.Combine(defaultHomePath, "Selected Mods");
        }

        public static string GetSmapiPath()
        {
            if (defaultGamePath is null) return string.Empty;
            
            var exePath = Path.Combine(defaultGamePath, "StardewModdingAPI.exe");
            var dllPath = Path.Combine(defaultGamePath, "StardewModdingAPI.dll");

            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return File.Exists(exePath) ? exePath : dllPath;
            }
            else
            {
                if (!File.Exists(dllPath) && File.Exists(exePath))
                {
                    return exePath;
                }
                return dllPath;
            }
        }

        internal static string GetSmapiLogFolderPath()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "StardewValley", "ErrorLogs");
            }

            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "StardewValley", "ErrorLogs");
        }

        public static string GetCacheFolderPath()
        {
            return Path.Combine(defaultHomePath, "Cache");
        }

        public static string GetVersionCachePath()
        {
            return Path.Combine(GetCacheFolderPath(), "Versions.json");
        }

        internal static string GetKeyCachePath()
        {
            return Path.Combine(GetCacheFolderPath(), "Keys.json");
        }

        internal static string GetDataCachePath()
        {
            return Path.Combine(GetCacheFolderPath(), "Data.json");
        }

        public static string GetNotionCachePath()
        {
            return Path.Combine(GetCacheFolderPath(), "Notion.json");
        }

        public static string GetLinksCachePath()
        {
            return Path.Combine(GetCacheFolderPath(), "Links.json");
        }

        public static string GetNexusPath()
        {
            return Path.Combine(defaultHomePath, "Nexus");
        }

        public static string GetThumbnailsPath()
        {
            return Path.Combine(defaultHomePath, "Thumbnails", "Nexus");
        }

        public static string GetSmapiUpgradeFolderPath()
        {
            return Path.Combine(defaultHomePath, "SMAPI");
        }
    }
}