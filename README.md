# Incus Podman VM and Noble FIPS image builder

This repository contains:

- `incus-podman-vm.sh`, which creates an Ubuntu 24.04 Incus VM with rootless
  Podman and Buildah.
- `Containerfile.fips`, which builds an Ubuntu Noble image with Ubuntu Pro
  FIPS packages.
- `build-fips-image.sh`, which passes an Ubuntu Pro attach configuration to
  Buildah as a temporary build secret.
- `pro-attach-config.toml.template`, a secret-free template for the attach
  configuration.

The FIPS image recipe follows Canonical's [FIPS Docker image guide](https://ubuntu.com/pro-client/docs/en/latest/howtoguides/create_a_fips_docker_image/),
adapted for Ubuntu Noble.

The VM is separate from the host kernel, so Podman and Buildah run inside a
real VM rather than an Incus container. This allows the Ubuntu 24.04 FIPS image
to be built on a host that is already FIPS-enabled.

## Prerequisites

On the Incus host, install Incus and the VM directory-sharing helper:

```bash
sudo apt update
sudo apt install -y incus virtiofsd
```

The image build needs network access to Ubuntu repositories and an Ubuntu Pro
token with access to FIPS services. For runtime FIPS enforcement, the host
kernel must be FIPS-enabled; the container supplies the remaining user-space
FIPS packages. See Canonical's [FIPS container guidance](https://ubuntu.com/security/certifications/docs/fips-cloud-containers).

## Create the VM

Run this on the Incus host from this repository:

```bash
./incus-podman-vm.sh
```

The defaults are:

- VM name: `podman-vm`
- User: `builder`
- CPUs: `2`
- Memory: `4GiB`
- Root disk: `30GiB`

Override them with environment variables when needed:

```bash
VM_NAME=fips-builder VM_CPU=4 VM_MEMORY=8GiB ./incus-podman-vm.sh
```

Enter the VM with:

```bash
incus exec podman-vm -- sudo --login --user builder
```

To have the setup script create the VM and open a shell afterward, use:

```bash
./incus-podman-vm.sh --shell
```

## Share this repository with the VM

The setup script prints these commands after provisioning. From the repository
directory on the host, run:

```bash
incus exec podman-vm -- mkdir -p /home/builder/host
incus config device add podman-vm workdir disk \
  source="$(pwd)" path=/home/builder/host io.bus=virtiofs
```

The repository is then available in the VM at `/home/builder/host`.

Remove the share when it is no longer needed:

```bash
incus config device remove podman-vm workdir
```

This repository deliberately uses virtiofs for VM shares. If `virtiofsd` is
missing, install it with:

```bash
sudo apt update && sudo apt install -y virtiofsd
```

## Create the Ubuntu Pro attach secret

1. Obtain an Ubuntu Pro token from the [Ubuntu Pro dashboard](https://ubuntu.com/pro/dashboard).
2. Copy the secret-free template:

   ```bash
   cp pro-attach-config.toml.template pro-attach-config.toml
   chmod 600 pro-attach-config.toml
   ```

3. Edit `pro-attach-config.toml` and replace
   `REPLACE_WITH_UBUNTU_PRO_TOKEN` with the token. Keep the
   `fips-updates` service enabled:

   ```yaml
   token: REPLACE_WITH_UBUNTU_PRO_TOKEN
   enable_services:
     - fips-updates
   ```

The file is named `.toml` for compatibility with this repository's existing
workflow, but Ubuntu Pro's attach configuration uses YAML syntax. The real
configuration is ignored by Git and is never copied into the image. The build
script passes it to Buildah using `--secret`, and the Containerfile mounts it
only while `pro attach` runs.

For better separation from the shared repository, create the file somewhere
inside the VM instead and pass its path explicitly:

```bash
cp ~/host/pro-attach-config.toml.template ~/pro-attach-config.yaml
chmod 600 ~/pro-attach-config.yaml
${EDITOR:-vi} ~/pro-attach-config.yaml
```

## Build the Noble FIPS image

Inside the VM, change to the shared repository and run the script through Bash:

```bash
cd ~/host
bash ./build-fips-image.sh
```

The default image tag is `ubuntu-noble-fips`. To use a config stored outside
the repository:

```bash
PRO_ATTACH_CONFIG=/home/builder/pro-attach-config.yaml \
  bash ./build-fips-image.sh
```

You can also provide the config as the first argument:

```bash
bash ./build-fips-image.sh /home/builder/pro-attach-config.yaml
```

The script requires Buildah, validates that the config contains a token field,
and passes the file as a Buildah secret. It does not print the token.

Noble requires the explicit `openssl-fips-module-3` package in this recipe;
see the Ubuntu Pro client's [Noble `fips-updates` provider issue](https://github.com/canonical/ubuntu-pro-client/issues/3487)
for the underlying behavior.

The `bash` invocation is intentional when the repository is on a virtiofs
share: executing a script directly from some virtiofs mounts can fail with
`/usr/bin/env: bad interpreter: Bad address`.

Check the resulting image and its FIPS OpenSSL module with:

```bash
podman images ubuntu-noble-fips
podman run --rm ubuntu-noble-fips \
  dpkg-query --show openssl openssl-fips-module-3
```

Use the current [Ubuntu FIPS documentation](https://documentation.ubuntu.com/security/compliance/fips/fips-overview/)
to confirm the certification status and package requirements for the release
and compliance target you need.

## Build ordinary images

The VM can also be used as a general rootless Podman/Buildah builder:

```bash
cd ~/host
podman build -t my-image .
buildah bud -t my-image .
```

The user `builder` is configured with subordinate UID/GID ranges and lingering
enabled so rootless container tools can operate from an interactive shell.
