$EMONGO_REPO = "https://github.com/comtihon/mongodb-erlang"
$PLUGINS_PATH = "plugins"

if (-Not (Test-Path -Path $PLUGINS_PATH)) {
    New-Item -ItemType directory $PLUGINS_PATH
}

cd plugins
git clone $EMONGO_REPO emongo
cd emongo
make