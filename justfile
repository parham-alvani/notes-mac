VERSION := `cat VERSION`
APP := "build/Daftar.app"
QL := "build/Daftar.app/Contents/PlugIns/DaftarQuickLook.appex"

default:
    @just --list

# the reading view's JavaScript, from web/src into Sources/Daftar/Reader
web:
    cd web && npm ci --silent && npm run build --silent

# a debug build
build: web
    swift build

# every test: the core in Swift, the renderer in node
test: web
    swift test
    cd web && npm test

# build/Daftar.app, signed ad hoc
app: web
    swift build -c release --arch arm64
    rm -rf {{ APP }}
    mkdir -p {{ APP }}/Contents/MacOS {{ APP }}/Contents/Resources
    cp "$(swift build -c release --arch arm64 --show-bin-path)/Daftar" {{ APP }}/Contents/MacOS/
    cp -R "$(swift build -c release --arch arm64 --show-bin-path)/Daftar_DaftarUI.bundle" {{ APP }}/Contents/Resources/
    # SwiftPM can keep an old copy of the reader: the one `just web` made is the one the app gets.
    # The bundle is `Contents/Resources/Reader` with the command line tools and flat with Xcode's SwiftPM.
    reader="$(find {{ APP }}/Contents/Resources/Daftar_DaftarUI.bundle -type d -name Reader | head -1)"; test -n "$reader" && cp -R Sources/DaftarUI/Reader/. "$reader/" && cmp -s Sources/DaftarUI/Reader/reader.js "$reader/reader.js"
    sed 's/VERSION/{{ VERSION }}/g' Support/Info.plist > {{ APP }}/Contents/Info.plist
    if [ -f Support/Daftar.icns ]; then cp Support/Daftar.icns {{ APP }}/Contents/Resources/; fi
    # The Quick Look extension: its executable, its Info.plist, the renderer and the reader's styles.
    mkdir -p {{ QL }}/Contents/MacOS {{ QL }}/Contents/Resources
    cp "$(swift build -c release --arch arm64 --show-bin-path)/DaftarQuickLook" {{ QL }}/Contents/MacOS/
    sed 's/VERSION/{{ VERSION }}/g' Support/QuickLook/Info.plist > {{ QL }}/Contents/Info.plist
    cp web/dist/quicklook.js Sources/DaftarUI/Reader/reader.css Sources/DaftarUI/Reader/tasks.css Sources/DaftarUI/Reader/callouts.css {{ QL }}/Contents/Resources/
    # Inside out, and without --deep: --deep signs the extension again without its sandbox, and Quick Look refuses it.
    codesign --force --sign - --entitlements Support/QuickLook/QuickLook.entitlements {{ QL }}
    codesign --force --sign - {{ APP }}
    @echo "{{ APP }} {{ VERSION }}"

# build the app and start it
run: app
    open {{ APP }}

# copy the app to /Applications
install: app
    rm -rf /Applications/Daftar.app
    cp -R {{ APP }} /Applications/

# Support/Daftar.icns from art/icon.png, the logo of Daftar on Android
icon:
    python3 Support/make-icon.py art/icon.png Support/Daftar.icns
