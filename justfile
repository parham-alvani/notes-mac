VERSION := `cat VERSION`
APP := "build/Daftar.app"

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
    sed 's/VERSION/{{ VERSION }}/g' Support/Info.plist > {{ APP }}/Contents/Info.plist
    if [ -f Support/Daftar.icns ]; then cp Support/Daftar.icns {{ APP }}/Contents/Resources/; fi
    codesign --force --deep --sign - {{ APP }}
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
