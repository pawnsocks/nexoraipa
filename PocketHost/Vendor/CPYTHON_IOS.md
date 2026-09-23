# CPython on iOS

PocketHost's Python adapter is already wired through `PythonKit`, but the actual CPython binary must be built/embedded on macOS because an iOS XCFramework cannot be produced on Linux.

## 1. Build CPython

```sh
./Scripts/build-cpython-ios.sh
```

This builds CPython 3.14.7 by default and copies `Python.xcframework` to `Vendor/Python.xcframework`.

## 2. Add the framework in Xcode

1. Open `PocketHost.xcodeproj`.
2. Drag `Vendor/Python.xcframework` into the project.
3. Target -> General -> Frameworks, Libraries and Embedded Content.
4. Set `Python.xcframework` to **Embed & Sign**.
5. In Build Settings set:
   - User Script Sandboxing = No
   - Enable Testability = Yes
   - Header Search Paths = `$(BUILT_PRODUCTS_DIR)/Python.framework/Headers`
   - Quoted Include In Framework Header = No

## 3. Process the Python standard library

Add a Run Script build phase after Copy Bundle Resources and before Embed Frameworks:

```sh
set -e
source "$PROJECT_DIR/Vendor/Python.xcframework/build/build_utils.sh"
install_python "$PROJECT_DIR/Vendor/Python.xcframework" "$PROJECT_DIR/PythonApp"
```

Then rebuild on the iPhone. `GET /api/v1/runtimes` should report Python as available, and the existing `POST /api/v1/runtimes/python/execute` endpoint will use it.

Do not download/execute arbitrary native extension modules at runtime. Native iOS code must be part of the signed app; pure Python modules/data can live inside the app sandbox.
