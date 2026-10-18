#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <sys/wait.h>
#include <errno.h>
#include <spawn.h>
#include <mach-o/dyld.h>
#include <copyfile.h>

typedef struct {
    const char *game_dir;
    const char *wine_prefix;
    const char *mods_path;
    const char *wine_bin;
    bool use_wine;
} LaunchConfig;

static void log_message(FILE *log, const char *message) {
    if (log) {
        fputs(message, log);
        fputc('\n', log);
        fflush(log);
    }
}

static bool host_is_arm64(void) {
#if defined(__aarch64__) || defined(__arm64__)
    return true;
#else
    return false;
#endif
}

static bool mach_slice_is_arm64(uint32_t cputype) {
    return cputype == CPU_TYPE_ARM64;
}

static bool mach_slice_is_x86_64(uint32_t cputype) {
    return cputype == CPU_TYPE_X86_64;
}

static void inspect_macho_slices(FILE *file, bool *has_arm64, bool *has_x86_64) {
    *has_arm64 = false;
    *has_x86_64 = false;

    uint32_t magic = 0;
    if (fread(&magic, sizeof(magic), 1, file) != 1) {
        return;
    }
    rewind(file);

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        struct fat_header header;
        if (fread(&header, sizeof(header), 1, file) != 1) {
            return;
        }

        uint32_t arch_count = OSSwapBigToHostInt32(header.nfat_arch);
        for (uint32_t i = 0; i < arch_count; i++) {
            struct fat_arch arch;
            if (fread(&arch, sizeof(arch), 1, file) != 1) {
                return;
            }

            uint32_t cputype = OSSwapBigToHostInt32(arch.cputype);
            if (mach_slice_is_arm64(cputype)) {
                *has_arm64 = true;
            }
            if (mach_slice_is_x86_64(cputype)) {
                *has_x86_64 = true;
            }
        }
        return;
    }

    uint32_t host_magic = magic;
    if (magic == MH_CIGAM || magic == MH_CIGAM_64) {
        host_magic = OSSwapInt32(magic);
    }

    if (host_magic == MH_MAGIC_64) {
        struct mach_header_64 header;
        rewind(file);
        if (fread(&header, sizeof(header), 1, file) != 1) {
            return;
        }
        if (mach_slice_is_arm64(header.cputype)) {
            *has_arm64 = true;
        }
        if (mach_slice_is_x86_64(header.cputype)) {
            *has_x86_64 = true;
        }
        return;
    }

    if (host_magic == MH_MAGIC) {
        struct mach_header header;
        rewind(file);
        if (fread(&header, sizeof(header), 1, file) != 1) {
            return;
        }
        if (mach_slice_is_arm64(header.cputype)) {
            *has_arm64 = true;
        }
        if (mach_slice_is_x86_64(header.cputype)) {
            *has_x86_64 = true;
        }
    }
}

static bool binary_supports_arm64(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) {
        return false;
    }

    bool has_arm64 = false;
    bool has_x86_64 = false;
    inspect_macho_slices(file, &has_arm64, &has_x86_64);
    fclose(file);
    return has_arm64;
}

static bool binary_is_intel_only(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) {
        return false;
    }

    bool has_arm64 = false;
    bool has_x86_64 = false;
    inspect_macho_slices(file, &has_arm64, &has_x86_64);
    fclose(file);
    return has_x86_64 && !has_arm64;
}

static int join_path(char *buffer, size_t size, const char *dir, const char *name) {
    int written = snprintf(buffer, size, "%s/%s", dir, name);
    return written > 0 && (size_t)written < size ? 0 : -1;
}

static void show_alert(const char *message) {
    char command[2048];
    snprintf(
        command,
        sizeof(command),
        "/usr/bin/osascript -e 'display dialog \"%s\" buttons {\"OK\"} default button \"OK\" with icon stop'",
        message
    );
    system(command);
}

static char *run_command_capture_output(const char *command) {
  FILE *fp = popen(command, "r");
  if (!fp) return NULL;
  char *out = NULL;
  size_t len = 0;
  char buf[256];
  while (fgets(buf, sizeof(buf), fp)) {
    size_t chunk = strlen(buf);
    char *n = realloc(out, len + chunk + 1);
    if (!n) {
      free(out);
      pclose(fp);
      return NULL;
    }
    out = n;
    memcpy(out + len, buf, chunk);
    len += chunk;
    out[len] = '\0';
  }
  pclose(fp);
  return out;
}

static int show_confirm(const char *message, const char *accept_label, const char *cancel_label) {
  char cmd[2048];
  snprintf(cmd, sizeof(cmd),
       "/usr/bin/osascript -e 'display dialog \"%s\" buttons {\"%s\",\"%s\"} default button \"%s\" with icon caution' -e 'button returned of result'",
       message, accept_label, cancel_label, accept_label);
  char *out = run_command_capture_output(cmd);
  if (!out) return 0;
  int accepted = strstr(out, accept_label) != NULL;
  free(out);
  return accepted;
}

static int install_rosetta(FILE *log) {
  log_message(log, "Attempting to install Rosetta using softwareupdate in Terminal...");

  pid_t pid = getpid();
  char status_path[PATH_MAX];
  snprintf(status_path, sizeof(status_path), "/tmp/rosetta_install_status_%d.txt", (int)pid);

  // Build AppleScript to open Terminal and run the installer, writing exit code to status file
  char as_cmd[4096];
    snprintf(as_cmd, sizeof(as_cmd),
     "tell application \"Terminal\" to do script \"echo Installing Rosetta...; /usr/sbin/softwareupdate --install-rosetta --agree-to-license; echo $? > %s; echo Rosetta install finished with exit code $?; echo Press Enter to close; read -r; exit\"",
     status_path);

  char full_cmd[8192];
  snprintf(full_cmd, sizeof(full_cmd), "/usr/bin/osascript -e '%s'", as_cmd);

  int sysret = system(full_cmd);
  if (sysret == -1) {
    log_message(log, "ERROR: Failed to launch Terminal for Rosetta install.");
    return 0;
  }

  // Wait for status file to appear with a timeout (10 minutes)
  const int max_wait = 600; // seconds
  int waited = 0;
  while (waited < max_wait) {
    if (access(status_path, F_OK) == 0) break;
    sleep(1);
    waited++;
  }

  if (access(status_path, F_OK) != 0) {
    log_message(log, "ERROR: Rosetta install did not complete within timeout.");
    return 0;
  }

  FILE *sf = fopen(status_path, "r");
  if (!sf) {
    log_message(log, "ERROR: Could not read Rosetta install status file.");
    return 0;
  }
  int code = -1;
  if (fscanf(sf, "%d", &code) != 1) code = -1;
  fclose(sf);
  unlink(status_path);

  if (code == 0) {
    log_message(log, "Rosetta installed successfully.");
    return 1;
  }

  char msg[128];
  snprintf(msg, sizeof(msg), "Rosetta install exited with code %d.", code);
  log_message(log, msg);
  return 0;
}

extern char **environ;

static int exec_with_arch(const char *path, char *const argv[]) {
  // Spawn /usr/bin/arch -x86_64 <path> <args...> so the wrapper stays running
  char *arch_argv[64];
  int i = 0;
  arch_argv[i++] = "/usr/bin/arch";
  arch_argv[i++] = "-x86_64";
  arch_argv[i++] = (char *)path;
  for (int j = 1; argv[j] != NULL && i < (int)(sizeof(arch_argv)/sizeof(arch_argv[0])) - 1; j++) {
    arch_argv[i++] = argv[j];
  }
  arch_argv[i] = NULL;

  pid_t pid;
  int status = 0;
  int res = posix_spawn(&pid, "/usr/bin/arch", NULL, NULL, arch_argv, environ);
  if (res != 0) {
    char msg[256];
    snprintf(msg, sizeof(msg), "ERROR: posix_spawn failed (%d) for arch wrapper", res);
    log_message(NULL, msg);
    return 1;
  }

  if (waitpid(pid, &status, 0) == -1) {
    log_message(NULL, "ERROR: waitpid failed while waiting for arch child process.");
    return 1;
  }
#ifdef WIFEXITED
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
#endif
  return 1;
}

static bool rosetta_installed(void) {
  int ret = system("/usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1");
  if (ret == -1) return false;
#ifdef WIFEXITED
  if (WIFEXITED(ret) && WEXITSTATUS(ret) == 0) return true;
#endif
  return false;
}

static int exec_with_args(const char *path, char *const argv[]) {
  pid_t pid;
  int status = 0;
  int res = posix_spawn(&pid, path, NULL, NULL, argv, environ);
  if (res != 0) {
    char msg[256];
    snprintf(msg, sizeof(msg), "ERROR: posix_spawn failed (%d) for %s", res, path);
    log_message(NULL, msg);
    return 1;
  }

  if (waitpid(pid, &status, 0) == -1) {
    log_message(NULL, "ERROR: waitpid failed while waiting for child process.");
    return 1;
  }
#ifdef WIFEXITED
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
#endif
  return 1;
}

static int launch_native(const LaunchConfig *config, FILE *log) {
    char smapi_path[PATH_MAX];

    if (chdir(config->game_dir) != 0) {
        log_message(log, "ERROR: Could not change directory to game folder.");
        return 1;
    }

    // Try a few possible native executable names: SMAPI or the renamed Stardew binary
    const char *candidates[] = {"StardewModdingAPI", "Stardew Valley", NULL};
    bool found = false;
    for (int i = 0; candidates[i] != NULL; i++) {
      if (join_path(smapi_path, sizeof(smapi_path), config->game_dir, candidates[i]) == 0 && access(smapi_path, X_OK) == 0) {
        found = true;
        break;
      }
    }
    if (!found) {
      log_message(log, "ERROR: Could not find native SMAPI/Stardew launcher.");
      show_alert("Could not find Native SMAPI/Stardew launcher in the configured game directory.");
      return 1;
    }

    if (host_is_arm64() && binary_is_intel_only(smapi_path)) {
      log_message(log, "SMAPI/Stardew executable appears to be Intel-only on this Mac.");
      if (rosetta_installed()) {
        log_message(log, "Rosetta already installed; launching executable under Rosetta (arch -x86_64)...");
        char *argv[] = {(char *)smapi_path, (char *)"--no-terminal", NULL};
        return exec_with_arch(smapi_path, argv);
      }

      int want_install = show_confirm(
        "The game executable is Intel-only on this Mac. Install Rosetta to run Intel binaries?",
        "Install Rosetta",
        "Cancel"
      );
      if (!want_install) {
        log_message(log, "User declined Rosetta install. Prompting to reinstall arm64 SMAPI.");
        show_alert("The game executable is Intel-only. Reinstall SMAPI/Stardew for Apple Silicon (arm64) or install Rosetta to run Intel binaries.");
        return 1;
      }

      if (!install_rosetta(log)) {
        show_alert("Rosetta installation failed or was cancelled. Cannot run Intel-only executable.");
        return 1;
      }

      log_message(log, "Launching Intel executable via Rosetta (arch -x86_64)...");
      char *argv[] = {(char *)smapi_path, (char *)"--no-terminal", NULL};
      return exec_with_arch(smapi_path, argv);
    }

    if (host_is_arm64() && !binary_supports_arm64(smapi_path)) {
      log_message(log, "ERROR: No arm64 slice found in the game executable for this Mac.");
      show_alert("No arm64 slice was found in the selected executable. Reinstall SMAPI/Stardew for Apple Silicon (arm64) or install Rosetta to run Intel binaries.");
      return 1;
    }

	    log_message(log, "Launching native SMAPI/Stardew as child process...");
	    char *argv[] = {(char *)smapi_path, (char *)"--no-terminal", NULL};
	    return exec_with_args(smapi_path, argv);
	}

static int launch_wine(const LaunchConfig *config, FILE *log) {
  char game_exe[PATH_MAX];
  char wine_dir[PATH_MAX];
  char path_env[PATH_MAX * 2];
  char dyld_env[PATH_MAX * 2];

  if (join_path(game_exe, sizeof(game_exe), config->game_dir, "StardewModdingAPI.exe") != 0 ||
      access(game_exe, F_OK) != 0) {
    log_message(log, "ERROR: Could not find Wine SMAPI executable.");
    show_alert("Could not find SMAPI at the configured Wine game directory.");
    return 1;
  }

  if (chdir(config->game_dir) != 0) {
    log_message(log, "ERROR: Could not change directory to game folder.");
    return 1;
  }

  setenv("WINEPREFIX", config->wine_prefix, 1);
  setenv("TERM", "xterm", 1);

  strncpy(wine_dir, config->wine_bin, sizeof(wine_dir) - 1);
  wine_dir[sizeof(wine_dir) - 1] = '\0';
  char *last_slash = strrchr(wine_dir, '/');
  if (last_slash) {
    *last_slash = '\0';
    last_slash = strrchr(wine_dir, '/');
    if (last_slash) {
      *last_slash = '\0';
    }
  }

  snprintf(path_env, sizeof(path_env), "%s/bin:/opt/homebrew/bin:/usr/local/bin:%s", wine_dir, getenv("PATH") ? getenv("PATH") : "");
  snprintf(dyld_env, sizeof(dyld_env), "%s/lib:%s", wine_dir, getenv("DYLD_LIBRARY_PATH") ? getenv("DYLD_LIBRARY_PATH") : "");
  setenv("PATH", path_env, 1);
  setenv("DYLD_LIBRARY_PATH", dyld_env, 1);

  log_message(log, "Executing Wine SMAPI...");
  char *argv[] = {(char *)config->wine_bin, (char *)"StardewModdingAPI.exe", NULL};
  return exec_with_args(config->wine_bin, argv);
}

static void parse_args(int argc, char *argv[], LaunchConfig *config) {
  config->game_dir = "";
  config->wine_prefix = "";
  config->mods_path = "";
  config->wine_bin = "wine";
  config->use_wine = false;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--game-dir") == 0 && i + 1 < argc) {
      config->game_dir = argv[++i];
    } else if (strcmp(argv[i], "--wine-prefix") == 0 && i + 1 < argc) {
      config->wine_prefix = argv[++i];
    } else if (strcmp(argv[i], "--mods-path") == 0 && i + 1 < argc) {
      config->mods_path = argv[++i];
    } else if (strcmp(argv[i], "--wine-bin") == 0 && i + 1 < argc) {
      config->wine_bin = argv[++i];
    } else if (strcmp(argv[i], "--use-wine") == 0) {
      config->use_wine = true;
    }
  }
}

int main(int argc, char *argv[]) {
  LaunchConfig config;
  parse_args(argc, argv, &config);

  const char *home = getenv("HOME");
  char log_path[PATH_MAX];
  if (home) {
    snprintf(log_path, sizeof(log_path), "%s/Library/Logs/StarfruitNative_SMAPI.log", home);
  } else {
    strncpy(log_path, "/tmp/StarfruitNative_SMAPI.log", sizeof(log_path));
    log_path[sizeof(log_path) - 1] = '\0';
  }

  FILE *log = fopen(log_path, "w");
  log_message(log, "--- Wrapper Launch ---");

  if (config.mods_path[0] != '\0') {
    setenv("SMAPI_MODS_PATH", config.mods_path, 1);
  }
  setenv("SMAPI_NO_TERMINAL", "true", 1);
  setenv("CORECLR_GLOBAL_INVARIANT", "1", 1);
  setenv("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", "1", 1);

  int result = config.use_wine ? launch_wine(&config, log) : launch_native(&config, log);
  if (result != 0) {
    log_message(log, "Wrapper exiting with launch failure.");
    if (log) {
      fclose(log);
    }
    return result;
  }

  log_message(log, "Wrapper exiting after failed exec.");
  if (log) {
    fclose(log);
  }
  return 1;
}
