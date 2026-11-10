# Stubs for testing `xz_dev.cc` off-device

These files let the *device-side* screenshot dumper (`main/xz_dev.cc` from
`patches/xz-dev-tools.patch`) be compiled as an ordinary native program and run without
an ESP32, so its output can be fed to the *host-side* decoder
(`scripts/py/extract_screenshots.py`).

They are fakes of the few ESP-IDF / firmware headers that file includes — just enough
surface to compile it unchanged. `harness.cc` supplies a fake display that returns
known byte strings of awkward lengths and writes the expected bytes to disk.

Run it with `scripts/17-test-screenshot-protocol.sh`. The compile happens inside the
ESP-IDF docker image (`scripts/container/test-xzshot.sh`, using the image's native g++);
nothing is built on the host.
