load("@envoy_build_config//:extensions_build_config.bzl", "EXTENSIONS", "WINDOWS_EXTENSIONS")

# Return all extensions to be compiled into Envoy.
def envoy_all_extensions():
    # These extensions are registered using the extension system but are required for the core
    # Envoy build.
    all_extensions = [
        "//source/extensions/transport_sockets/raw_buffer:config",
        "//source/extensions/transport_sockets/ssl:config",
    ]

    # These extensions can be removed on a site specific basis.
    for path in EXTENSIONS.values():
        all_extensions.append(path)

    return all_extensions

def envoy_windows_extensions():
    # These extensions are registered using the extension system but are required for the core
    # Envoy build.
    windows_extensions = [
        "//source/extensions/transport_sockets/raw_buffer:config",
        "//source/extensions/transport_sockets/ssl:config",
    ]

    # These extensions can be removed on a site specific basis.
    for path in WINDOWS_EXTENSIONS.values():
        windows_extensions.append(path)

    return windows_extensions

def envoy_ppc_extensions():
    all_extensions = envoy_all_extensions()
    luajit_path=''
    for extension_path in all_extensions:
       if extension_path.find("lua") > 0:
          luajit_path=extension_path
    if luajit_path != '':
       all_extensions.remove(luajit_path)
    return all_extensions

