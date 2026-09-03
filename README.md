```sh
# homebrew install (linux & macos):
NONINTERACTIVE=1 /bin/bash -c \
"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
command -v brew >/dev/null 2>&1 || \
    export PATH="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$PATH"
command -v brew >/dev/null 2>&1 && \
    eval "$(brew shellenv)"
```

```sh
# linux & macos (brew):
brew install -y git gh
```

```sh
# termux:
pkg update && pkg install -y git gh
```

```sh
# debian based:
sudo apt update && sudo apt install -y git gh
```


