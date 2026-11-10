// Host harness for xz_dev.cc: a fake display hands out known payloads of awkward sizes
// (around the 3-byte base64 group and the 72-byte line boundary, plus a large one),
// the real dumper prints them, and the expected bytes are saved for comparison.
//
// usage: harness <expected-dir>     (stdout = what the device would print)
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "board.h"

void XzDevStart();

static const std::vector<size_t> kSizes = {XZ_TEST_SIZES};
static std::string g_dir;

class FakeDisplay : public Display {
public:
    bool SnapshotToJpeg(std::string& out, int) override {
        size_t n = kSizes[call_ % kSizes.size()];
        out.clear();
        uint32_t x = 0x12345678u + static_cast<uint32_t>(call_);
        for (size_t i = 0; i < n; i++) {           // xorshift: every byte value shows up
            x ^= x << 13; x ^= x >> 17; x ^= x << 5;
            out.push_back(static_cast<char>(x & 0xFF));
        }
        char name[512];
        snprintf(name, sizeof(name), "%s/expected-%02d.bin", g_dir.c_str(), call_ + 1);
        FILE* f = fopen(name, "wb");
        if (!f) { return false; }
        fwrite(out.data(), 1, out.size(), f);
        fclose(f);
        call_++;
        return true;
    }
private:
    int call_ = 0;
};

Display* Board::GetDisplay() { static FakeDisplay d; return &d; }

int main(int argc, char** argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <expected-dir>\n", argv[0]); return 2; }
    g_dir = argv[1];
    puts("I (100) main: some unrelated log line before the screenshots");
    XzDevStart();
    puts("I (9999) main: some unrelated log line after the screenshots");
    return 0;
}
