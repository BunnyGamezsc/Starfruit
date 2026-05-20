using Semver;
using Stardrop.Models;
using Stardrop.Models.SMAPI;
using Stardrop.Models.SMAPI.Web;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace Stardrop.Utilities.External
{
    static class SMAPI
    {
        internal static bool IsRunning = false;
        internal static Process Process;

        public static ProcessStartInfo GetPrepareProcess(bool hideConsole)
        {
            var smapiInfo = new FileInfo(Pathing.GetSmapiPath());

            var fileName = smapiInfo.FullName;
            var arguments = string.Empty;
            var parsedModPath = string.Empty;
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux) is true)
            {
                fileName = "/usr/bin/env";
                arguments = $"bash -c \"SMAPI_MODS_PATH='{Pathing.GetSelectedModsFolderPath()}' '{Pathing.GetSmapiPath().Replace("StardewModdingAPI.dll", "StardewValley")}'\"";
                parsedModPath = $"'{Pathing.GetSelectedModsFolderPath()}'";
            }
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX) is true)
            {
                var baseDir = AppDomain.CurrentDomain.BaseDirectory;
                var resourcesDir = Path.GetFullPath(Path.Combine(baseDir, "..", "Resources"));
                var targetDir = Directory.Exists(resourcesDir) ? resourcesDir : baseDir;
                
                var appPath = Path.Combine(targetDir, "SMAPI-Wine.app");
                var macosPath = Path.Combine(appPath, "Contents", "MacOS");
                if (!Directory.Exists(macosPath))
                {
                    Directory.CreateDirectory(macosPath);
                }

                var scriptPath = Path.Combine(macosPath, "SMAPI");
                var scriptContent = $"#!/bin/bash\nexport SMAPI_USE_CURRENT_SHELL=true\nexport PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\nexport TERM=xterm\ncd \"{smapiInfo.DirectoryName}\"\nWINEPREFIX=\"{Program.settings.WinePrefixPath}\" wine StardewModdingAPI.exe \"$@\"";
                File.WriteAllText(scriptPath, scriptContent);
                
                var plistPath = Path.Combine(appPath, "Contents", "Info.plist");
                var plistContent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n<key>CFBundleExecutable</key>\n<string>SMAPI</string>\n<key>CFBundleIdentifier</key>\n<string>com.stardrop.smapi-wrapper</string>\n<key>CFBundleName</key>\n<string>SMAPI-Wine</string>\n<key>CFBundlePackageType</key>\n<string>APPL</string>\n<key>LSUIElement</key>\n<true/>\n</dict>\n</plist>";
                File.WriteAllText(plistPath, plistContent);
                
                // Make the wrapper app executable
                new Process { StartInfo = new ProcessStartInfo { FileName = "chmod", Arguments = $"+x \"{scriptPath}\"", CreateNoWindow = true } }.Start();

                fileName = scriptPath;
                arguments = $"--mods-path \"{Pathing.GetSelectedModsFolderPath()}\"";
                parsedModPath = $"{Pathing.GetSelectedModsFolderPath()}";
                /* Alternative route (using AppleScript) of activating Terminal + SMAPI
                fileName = "/usr/bin/env";
                arguments = $@"osascript -e ""tell application \""Terminal\""
                set smapi_path to \""{Pathing.GetSmapiPath().Replace("StardewModdingAPI.dll", "StardewModdingAPI")}\""
                set mods_path to \""{Pathing.GetSelectedModsFolderPath()}\""
                activate
                do script \""\"" & quoted form of the POSIX path of smapi_path & \"" --mods-path \"" & quoted form of the POSIX path of mods_path
                end tell""";
                */
            }
            else
            {
                parsedModPath = Pathing.GetSelectedModsFolderPath();
            }

            Program.helper.Log($"Starting SMAPI with the following arguments: {arguments}");
            var processInfo = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                WorkingDirectory = smapiInfo.DirectoryName,
                RedirectStandardOutput = false,
                RedirectStandardError = false,
                CreateNoWindow = hideConsole,
                UseShellExecute = false
            };

            // Set SMAPI_MODS_PATH EnvironmentVariable if required
            if (string.IsNullOrEmpty(parsedModPath) is false)
            {
                Program.helper.Log($"Setting SMAPI_MODS_PATH to: {parsedModPath}");
                processInfo.EnvironmentVariables["SMAPI_MODS_PATH"] = parsedModPath;

                Program.helper.Log($"Process SMAPI_MODS_PATH: {processInfo.EnvironmentVariables["SMAPI_MODS_PATH"]}");
                Program.helper.Log($"System SMAPI_MODS_PATH: {Environment.GetEnvironmentVariable("SMAPI_MODS_PATH")}");
            }

            return processInfo;
        }

        public static string GetProcessName()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            {
                return "StardewModdingA";
            }

            return "StardewModdingAPI";
        }

        public async static Task<List<ModEntry>> GetModUpdateData(GameDetails gameDetails, List<Mod> mods)
        {
            List<ModSearchEntry> searchEntries = new List<ModSearchEntry>();
            foreach (var mod in mods.Where(m => m.HasValidVersion() && m.HasUpdateKeys()))
            {
                searchEntries.Add(new ModSearchEntry(mod.UniqueId, mod.Version, mod.Manifest.UpdateKeys));
            }
            foreach (var requirementKey in mods.SelectMany(m => m.Requirements))
            {
                if (!searchEntries.Any(e => e.Id.Equals(requirementKey.UniqueID, StringComparison.OrdinalIgnoreCase)))
                {
                    searchEntries.Add(new ModSearchEntry() { Id = requirementKey.UniqueID });
                }
            }

            // Create the body to be sent via the POST request
            ModSearchData searchData = new ModSearchData(searchEntries, gameDetails.SmapiVersion, gameDetails.GameVersion, gameDetails.System.ToString(), true);

            // Create a throwaway client
            HttpClient client = new HttpClient();
            client.DefaultRequestHeaders.Add("Application-Name", "Stardrop");
            client.DefaultRequestHeaders.Add("Application-Version", Program.ApplicationVersion);
            client.DefaultRequestHeaders.Add("User-Agent", $"Stardrop/{Program.ApplicationVersion} {Environment.OSVersion}");

            var parsedRequest = JsonSerializer.Serialize(searchData, new JsonSerializerOptions() { WriteIndented = true, IgnoreNullValues = true });
            var requestPackage = new StringContent(parsedRequest, Encoding.UTF8, "application/json");
            var response = await client.PostAsync("https://smapi.io/api/v3.0/mods", requestPackage);

            List<ModEntry> modUpdateData = new List<ModEntry>();
            if (response.StatusCode == System.Net.HttpStatusCode.OK && response.Content is not null)
            {
                // In the name of the Nine Divines, why is JsonSerializer.Deserialize case sensitive by default???
                string content = await response.Content.ReadAsStringAsync();
                modUpdateData = JsonSerializer.Deserialize<List<ModEntry>>(content, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

                if (modUpdateData is null || modUpdateData.Count == 0)
                {
                    Program.helper.Log($"Mod update data was not parsable from smapi.io");
                    Program.helper.Log($"Response from smapi.io:\n{content}");
                    Program.helper.Log($"Our request to smapi.io:\n{parsedRequest}");
                }
            }
            else
            {
                if (response.StatusCode != System.Net.HttpStatusCode.OK)
                {
                    Program.helper.Log($"Bad status given from smapi.io: {response.StatusCode}");
                    if (response.Content is not null)
                    {
                        Program.helper.Log($"Response from smapi.io:\n{await response.Content.ReadAsStringAsync()}");
                    }
                }
                else if (response.Content is null)
                {
                    Program.helper.Log($"No response from smapi.io!");
                }
                else
                {
                    Program.helper.Log($"Error getting mod update data from smapi.io!");
                }

                Program.helper.Log($"Our request to smapi.io:\n{parsedRequest}");
            }

            client.Dispose();

            return modUpdateData;
        }

        internal static SemVersion? GetVersion()
        {
            try 
            {
                AssemblyName smapiAssembly = AssemblyName.GetAssemblyName(Pathing.GetSmapiPath());

                if (smapiAssembly is null || smapiAssembly.Version is null)
                {
                    return null;
                }

                return SemVersion.Parse($"{smapiAssembly.Version.Major}.{smapiAssembly.Version.Minor}.{smapiAssembly.Version.Build}", SemVersionStyles.Any);
            }
            catch
            {
                return null;
            }
        }
    }
}
