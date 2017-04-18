# Copyright 2016 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Rules for configuring the C++ toolchain (experimental)."""


def _get_value(it):
  """Convert `it` in serialized protobuf format."""
  if type(it) == "int":
    return str(it)
  elif type(it) == "bool":
    return "true" if it else "false"
  else:
    return "\"%s\"" % it


def _build_crosstool(d, prefix="  "):
  """Convert `d` to a string version of a CROSSTOOL file content."""
  lines = []
  for k in d:
    if type(d[k]) == "list":
      for it in d[k]:
        lines.append("%s%s: %s" % (prefix, k, _get_value(it)))
    else:
      lines.append("%s%s: %s" % (prefix, k, _get_value(d[k])))
  return "\n".join(lines)


def _build_tool_path(d):
  """Build the list of tool_path for the CROSSTOOL file."""
  lines = []
  for k in d:
    lines.append("  tool_path {name: \"%s\" path: \"%s\" }" % (k, d[k]))
  return "\n".join(lines)

def auto_configure_fail(msg):
  """Output failure message when auto configuration fails."""
  red = "\033[0;31m"
  no_color = "\033[0m"
  fail("\n%sAuto-Configuration Error:%s %s\n" % (red, no_color, msg))


def auto_configure_warning(msg):
  """Output warning message during auto configuration."""
  yellow = "\033[1;33m"
  no_color = "\033[0m"
  print("\n%sAuto-Configuration Warning:%s %s\n" % (yellow, no_color, msg))


def _get_env_var(repository_ctx, name, default = None, enable_warning = True):
  """Find an environment variable in system path."""
  if name in repository_ctx.os.environ:
    return repository_ctx.os.environ[name]
  if default != None:
    if enable_warning:
      auto_configure_warning("'%s' environment variable is not set, using '%s' as default" % (name, default))
    return default
  auto_configure_fail("'%s' environment variable is not set" % name)


def _which(repository_ctx, cmd, default = None):
  """A wrapper around repository_ctx.which() to provide a fallback value."""
  result = repository_ctx.which(cmd)
  return default if result == None else str(result)


def _which_cmd(repository_ctx, cmd, default = None):
  """Find cmd in PATH using repository_ctx.which() and fail if cannot find it."""
  result = repository_ctx.which(cmd)
  if result != None:
    return str(result)
  path = _get_env_var(repository_ctx, "PATH")
  if default != None:
    auto_configure_warning("Cannot find %s in PATH, using '%s' as default.\nPATH=%s" % (cmd, default, path))
    return default
  auto_configure_fail("Cannot find %s in PATH, please make sure %s is installed and add its directory in PATH.\nPATH=%s" % (cmd, cmd, path))
  return str(result)


def _execute(repository_ctx, command, environment = None):
  """Execute a command, return stdout if succeed and throw an error if it fails."""
  if environment:
    result = repository_ctx.execute(command, environment = environment)
  else:
    result = repository_ctx.execute(command)
  if result.stderr:
    auto_configure_fail(result.stderr)
  else:
    return result.stdout.strip()


def _get_tool_paths(repository_ctx, darwin, cc):
  """Compute the path to the various tools."""
  return {k: _which(repository_ctx, k, "/usr/bin/" + k)
          for k in [
              "ld",
              "cpp",
              "dwp",
              "gcov",
              "nm",
              "objcopy",
              "objdump",
              "strip",
          ]} + {
              "gcc": cc,
              "ar": "/usr/bin/libtool"
                    if darwin else _which(repository_ctx, "ar", "/usr/bin/ar")
          }


def _cplus_include_paths(repository_ctx):
  """Use ${CPLUS_INCLUDE_PATH} to compute the list of flags for cxxflag."""
  if "CPLUS_INCLUDE_PATH" in repository_ctx.os.environ:
    result = []
    for p in repository_ctx.os.environ["CPLUS_INCLUDE_PATH"].split(":"):
      p = str(repository_ctx.path(p))  # Normalize the path
      result.append("-I" + p)
    return result
  else:
    return []


def _get_cpu_value(repository_ctx):
  """Compute the cpu_value based on the OS name."""
  os_name = repository_ctx.os.name.lower()
  if os_name.startswith("mac os"):
    return "darwin"
  if os_name.find("freebsd") != -1:
    return "freebsd"
  if os_name.find("windows") != -1:
    return "x64_windows"
  # Use uname to figure out whether we are on x86_32 or x86_64
  result = repository_ctx.execute(["uname", "-m"])
  if result.stdout.strip() in ["power", "ppc64le", "ppc"]:
    return "ppc"
  if result.stdout.strip() in ["arm", "armv7l", "aarch64"]:
    return "arm"
  return "k8" if result.stdout.strip() in ["amd64", "x86_64", "x64"] else "piii"


_INC_DIR_MARKER_BEGIN = "#include <...>"

# OSX add " (framework directory)" at the end of line, strip it.
_OSX_FRAMEWORK_SUFFIX = " (framework directory)"
_OSX_FRAMEWORK_SUFFIX_LEN =  len(_OSX_FRAMEWORK_SUFFIX)
def _cxx_inc_convert(path):
  """Convert path returned by cc -E xc++ in a complete path."""
  path = path.strip()
  if path.endswith(_OSX_FRAMEWORK_SUFFIX):
    path = path[:-_OSX_FRAMEWORK_SUFFIX_LEN].strip()
  return path

def _get_cxx_inc_directories(repository_ctx, cc):
  """Compute the list of default C++ include directories."""
  result = repository_ctx.execute([cc, "-E", "-xc++", "-", "-v"])
  index1 = result.stderr.find(_INC_DIR_MARKER_BEGIN)
  if index1 == -1:
    return []
  index1 = result.stderr.find("\n", index1)
  if index1 == -1:
    return []
  index2 = result.stderr.rfind("\n ")
  if index2 == -1 or index2 < index1:
    return []
  index2 = result.stderr.find("\n", index2 + 1)
  if index2 == -1:
    inc_dirs = result.stderr[index1 + 1:]
  else:
    inc_dirs = result.stderr[index1 + 1:index2].strip()

  return [repository_ctx.path(_cxx_inc_convert(p))
          for p in inc_dirs.split("\n")]

def _add_option_if_supported(repository_ctx, cc, option):
  """Checks that `option` is supported by the C compiler."""
  result = repository_ctx.execute([
      cc,
      option,
      "-o",
      "/dev/null",
      "-c",
      str(repository_ctx.path("tools/cpp/empty.cc"))
  ])
  return [option] if result.stderr.find(option) == -1 else []

def _is_gold_supported(repository_ctx, cc):
  """Checks that `gold` is supported by the C compiler."""
  result = repository_ctx.execute([
      cc,
      "-fuse-ld=gold",
      "-o",
      "/dev/null",
      # Some macos clang versions don't fail when setting -fuse-ld=gold, adding
      # these lines to force it to. This also means that we will not detect
      # gold when only a very old (year 2010 and older) is present.
      "-Wl,--start-lib",
      "-Wl,--end-lib",
      str(repository_ctx.path("tools/cpp/empty.cc"))
  ])
  return result.return_code == 0

def _crosstool_content(repository_ctx, cc, cpu_value, darwin):
  """Return the content for the CROSSTOOL file, in a dictionary."""
  supports_gold_linker = _is_gold_supported(repository_ctx, cc)
  return {
      "abi_version": _get_env_var(repository_ctx, "ABI_VERSION", "local", False),
      "abi_libc_version": _get_env_var(repository_ctx, "ABI_LIBC_VERSION", "local", False),
      "builtin_sysroot": "",
      "compiler": _get_env_var(repository_ctx, "BAZEL_COMPILER", "compiler", False),
      "host_system_name": _get_env_var(repository_ctx, "BAZEL_HOST_SYSTEM", "local", False),
      "needsPic": True,
      "supports_gold_linker": supports_gold_linker,
      "supports_incremental_linker": False,
      "supports_fission": False,
      "supports_interface_shared_objects": False,
      "supports_normalizing_ar": False,
      "supports_start_end_lib": supports_gold_linker,
      "target_libc": "macosx" if darwin else _get_env_var(repository_ctx, "BAZEL_TARGET_LIBC", "local", False),
      "target_cpu": _get_env_var(repository_ctx, "BAZEL_TARGET_CPU", cpu_value, False),
      "target_system_name": _get_env_var(repository_ctx, "BAZEL_TARGET_SYSTEM", "local", False),
      "cxx_flag": [
          "-std=c++0x",
      ] + _cplus_include_paths(repository_ctx),
      "linker_flag": [
          "-lstdc++",
          "-lm",  # Some systems expect -lm in addition to -lstdc++
          # Anticipated future default.
      ] + (
          ["-fuse-ld=gold"] if supports_gold_linker else []
      ) + _add_option_if_supported(
          repository_ctx, cc, "-Wl,-no-as-needed"
      ) + _add_option_if_supported(
          repository_ctx, cc, "-Wl,-z,relro,-z,now"
      ) + (
          [
              "-undefined",
              "dynamic_lookup",
              "-headerpad_max_install_names",
          ] if darwin else [
              "-B" + str(repository_ctx.path(cc).dirname),
              # Always have -B/usr/bin, see https://github.com/bazelbuild/bazel/issues/760.
              "-B/usr/bin",
              # Stamp the binary with a unique identifier.
              "-Wl,--build-id=md5",
              "-Wl,--hash-style=gnu"
              # Gold linker only? Can we enable this by default?
              # "-Wl,--warn-execstack",
              # "-Wl,--detect-odr-violations"
          ] + _add_option_if_supported(
              # Have gcc return the exit code from ld.
              repository_ctx, cc, "-pass-exit-codes"
          )
      ),
      "ar_flag": ["-static", "-s", "-o"] if darwin else [],
      "cxx_builtin_include_directory": _get_cxx_inc_directories(repository_ctx, cc),
      "objcopy_embed_flag": ["-I", "binary"],
      "unfiltered_cxx_flag":
          # If the compiler sometimes rewrites paths in the .d files without symlinks
          # (ie when they're shorter), it confuses Bazel's logic for verifying all
          # #included header files are listed as inputs to the action.
          _add_option_if_supported(repository_ctx, cc, "-fno-canonical-system-headers") + [
              # Make C++ compilation deterministic. Use linkstamping instead of these
              # compiler symbols.
              "-Wno-builtin-macro-redefined",
              "-D__DATE__=\\\"redacted\\\"",
              "-D__TIMESTAMP__=\\\"redacted\\\"",
              "-D__TIME__=\\\"redacted\\\""
          ],
      "compiler_flag": [
          # Security hardening requires optimization.
          # We need to undef it as some distributions now have it enabled by default.
          "-U_FORTIFY_SOURCE",
          "-fstack-protector",
          # All warnings are enabled. Maybe enable -Werror as well?
          "-Wall",
          # Enable a few more warnings that aren't part of -Wall.
      ] + (["-Wthread-safety", "-Wself-assign"] if darwin else [
          "-B" + str(repository_ctx.path(cc).dirname),
          # Always have -B/usr/bin, see https://github.com/bazelbuild/bazel/issues/760.
          "-B/usr/bin",
      ]) + (
          # Disable problematic warnings.
          _add_option_if_supported(repository_ctx, cc, "-Wunused-but-set-parameter") +
          # has false positives
          _add_option_if_supported(repository_ctx, cc, "-Wno-free-nonheap-object") +
          # Enable coloring even if there's no attached terminal. Bazel removes the
          # escape sequences if --nocolor is specified.
          _add_option_if_supported(repository_ctx, cc, "-fcolor-diagnostics")) + [
              # Keep stack frames for debugging, even in opt mode.
              "-fno-omit-frame-pointer",
          ],
  }

# TODO(pcloudy): Remove this after MSVC CROSSTOOL becomes default on Windows
def _get_windows_msys_crosstool_content(repository_ctx):
  """Return the content of msys crosstool which is still the default CROSSTOOL on Windows."""
  bazel_sh = _get_env_var(repository_ctx, "BAZEL_SH").replace("\\", "/").lower()
  tokens = bazel_sh.rsplit("/", 1)
  msys_root = None
  if tokens[0].endswith("/usr/bin"):
    msys_root = tokens[0][:len(tokens[0]) - len("usr/bin")]
  elif tokens[0].endswith("/bin"):
    msys_root = tokens[0][:len(tokens[0]) - len("bin")]
  if not msys_root:
    auto_configure_fail(
        "Could not determine MSYS/Cygwin root from BAZEL_SH (%s)" % bazel_sh)
  return (
      '   abi_version: "local"\n' +
      '   abi_libc_version: "local"\n' +
      '   builtin_sysroot: ""\n' +
      '   compiler: "windows_msys64"\n' +
      '   host_system_name: "local"\n' +
      "   needsPic: false\n" +
      '   target_libc: "local"\n' +
      '   target_cpu: "x64_windows_msys"\n' +
      '   target_system_name: "local"\n' +
      '   tool_path { name: "ar" path: "%susr/bin/ar" }\n' % msys_root +
      '   tool_path { name: "compat-ld" path: "%susr/bin/ld" }\n' % msys_root +
      '   tool_path { name: "cpp" path: "%susr/bin/cpp" }\n' % msys_root +
      '   tool_path { name: "dwp" path: "%susr/bin/dwp" }\n' % msys_root +
      '   tool_path { name: "gcc" path: "%susr/bin/gcc" }\n' % msys_root +
      '   cxx_flag: "-std=gnu++0x"\n' +
      '   linker_flag: "-lstdc++"\n' +
      '   cxx_builtin_include_directory: "%s"\n' % msys_root +
      '   cxx_builtin_include_directory: "/usr/"\n' +
      '   tool_path { name: "gcov" path: "%susr/bin/gcov" }\n' % msys_root +
      '   tool_path { name: "ld" path: "%susr/bin/ld" }\n' % msys_root +
      '   tool_path { name: "nm" path: "%susr/bin/nm" }\n' % msys_root +
      '   tool_path { name: "objcopy" path: "%susr/bin/objcopy" }\n' % msys_root +
      '   objcopy_embed_flag: "-I"\n' +
      '   objcopy_embed_flag: "binary"\n' +
      '   tool_path { name: "objdump" path: "%susr/bin/objdump" }\n' % msys_root +
      '   tool_path { name: "strip" path: "%susr/bin/strip" }'% msys_root )

def _opt_content(darwin):
  """Return the content of the opt specific section of the CROSSTOOL file."""
  return {
      "compiler_flag": [
          # No debug symbols.
          # Maybe we should enable https://gcc.gnu.org/wiki/DebugFission for opt or
          # even generally? However, that can't happen here, as it requires special
          # handling in Bazel.
          "-g0",

          # Conservative choice for -O
          # -O3 can increase binary size and even slow down the resulting binaries.
          # Profile first and / or use FDO if you need better performance than this.
          "-O2",

          # Security hardening on by default.
          # Conservative choice; -D_FORTIFY_SOURCE=2 may be unsafe in some cases.
          "-D_FORTIFY_SOURCE=1",

          # Disable assertions
          "-DNDEBUG",

          # Removal of unused code and data at link time (can this increase binary size in some cases?).
          "-ffunction-sections",
          "-fdata-sections"
      ],
      "linker_flag": [] if darwin else ["-Wl,--gc-sections"]
  }


def _dbg_content():
  """Return the content of the dbg specific section of the CROSSTOOL file."""
  # Enable debug symbols
  return {"compiler_flag": "-g"}


def _get_system_root(repository_ctx):
  r"""Get System root path on Windows, default is C:\\Windows."""
  if "SYSTEMROOT" in repository_ctx.os.environ:
    return repository_ctx.os.environ["SYSTEMROOT"]
  auto_configure_warning("SYSTEMROOT is not set, using default SYSTEMROOT=C:\\Windows")
  return "C:\\Windows"

def _find_cc(repository_ctx):
  """Find the C++ compiler."""
  cc_name = "gcc"
  if "CC" in repository_ctx.os.environ:
    cc_name = repository_ctx.os.environ["CC"].strip()
    if not cc_name:
      cc_name = "gcc"
  if cc_name.startswith("/"):
    # Absolute path, maybe we should make this suported by our which function.
    return cc_name
  cc = repository_ctx.which(cc_name)
  if cc == None:
    fail(
        "Cannot find gcc, either correct your path or set the CC" +
        " environment variable")
  return cc


def _find_cuda(repository_ctx):
  """Find out if and where cuda is installed."""
  if "CUDA_PATH" in repository_ctx.os.environ:
    return repository_ctx.os.environ["CUDA_PATH"]
  nvcc = _which(repository_ctx, "nvcc.exe")
  if nvcc:
    return nvcc[:-len("/bin/nvcc.exe")]
  return None

# Find a good path for the C++ compiler, by hooking into Bazel's C compiler
# detection. Uses `$CXX` if found, otherwise defaults to `g++` because Bazel
# defaults to `gcc`.
def _find_cxx(repository_ctx):
  # Bazel's `find_cc` helper uses the repository context to inspect `$CC`.
  # Replace this value with `$CXX` if set.
  environ_cxx = repository_ctx.os.environ.get("CXX", "g++")
  fake_os = struct(
    environ = {"CC": environ_cxx},
  )

  # We can't directly assign `repository_ctx.which` to a struct attribute
  # because Skylark doesn't support bound method references. Instead, stub
  # out `which()` using a two-pass approach:
  #
  # * The first pass uses a stub that always succeeds, passing back a special
  #   value containing the original parameter.
  # * If we detect the special value, we know that `find_cc` found a compiler
  #   name but don't know if that name could be resolved to an executable path.
  #   So do the `which()` call ourselves.
  # * If our `which()` failed, call `find_cc` again with a dummy which that
  #   always fails. The error raised by `find_cc` will be identical to what Bazel
  #   would generate for a missing C compiler.
  #
  # See https://github.com/bazelbuild/bazel/issues/4644 for more context.
  real_cxx = find_cc(struct(
      which = _quiet_fake_which,
      os = fake_os,
  ), {})
  if hasattr(real_cxx, "_envoy_fake_which"):
    real_cxx = repository_ctx.which(real_cxx._envoy_fake_which)
    if real_cxx == None:
      find_cc(struct(
        which = _noisy_fake_which,
        os = fake_os,
      ), {})
  return real_cxx

def _build_envoy_cc_wrapper(repository_ctx):
  real_cc = find_cc(repository_ctx, {})
  real_cxx = _find_cxx(repository_ctx)

  # Copy our CC wrapper script into @local_config_cc, with the true paths
  # to the C and C++ compiler injected in. The wrapper will use these paths
  # to invoke the compiler after deciding which one is correct for the current
  # invocation.
  #
  # Since the script is Python, we can inject values using `repr(str(value))`
  # and escaping will be handled correctly.
  repository_ctx.template("extra_tools/envoy_cc_wrapper", repository_ctx.attr._envoy_cc_wrapper, {
      "{ENVOY_REAL_CC}": repr(str(real_cc)),
      "{ENVOY_REAL_CXX}": repr(str(real_cxx)),
  })
  return repository_ctx.path("extra_tools/envoy_cc_wrapper")

def _needs_envoy_cc_wrapper(repository_ctx):
  # When building for Linux we set additional C++ compiler options that aren't
  # handled well by Bazel, so we need a wrapper around $CC to fix its
  # compiler invocations.
  cpu_value = get_cpu_value(repository_ctx)
  return cpu_value not in ["freebsd", "x64_windows", "darwin"]

def cc_autoconf_impl(repository_ctx):
  overriden_tools = {}
  if _needs_envoy_cc_wrapper(repository_ctx):
    # Bazel uses "gcc" as a generic name for all C and C++ compilers.
    overriden_tools["gcc"] = _build_envoy_cc_wrapper(repository_ctx)
  return _upstream_cc_autoconf_impl(repository_ctx, overriden_tools=overriden_tools)

cc_autoconf = repository_rule(
    implementation=_impl,
    environ = [
        "ABI_LIBC_VERSION",
        "ABI_VERSION",
        "BAZEL_COMPILER",
        "BAZEL_HOST_SYSTEM",
        "BAZEL_PYTHON",
        "BAZEL_SH",
        "BAZEL_TARGET_CPU",
        "BAZEL_TARGET_LIBC",
        "BAZEL_TARGET_SYSTEM",
        "BAZEL_VC",
        "BAZEL_VS",
        "CC",
        "CC_TOOLCHAIN_NAME",
        "CPLUS_INCLUDE_PATH",
        "CUDA_COMPUTE_CAPABILITIES",
        "CUDA_PATH",
        "HOMEBREW_RUBY_PATH",
        "NO_WHOLE_ARCHIVE_OPTION",
        "SYSTEMROOT",
        "VS90COMNTOOLS",
        "VS100COMNTOOLS",
        "VS110COMNTOOLS",
        "VS120COMNTOOLS",
        "VS140COMNTOOLS"])


def cc_configure():
  """A C++ configuration rules that generate the crosstool file."""
  cc_autoconf(name="local_config_cc")
  native.bind(name="cc_toolchain", actual="@local_config_cc//:toolchain")
