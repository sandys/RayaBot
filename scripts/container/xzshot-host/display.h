#pragma once
#include <string>
class Display {
public:
    virtual ~Display() = default;
    virtual bool SnapshotToJpeg(std::string& jpeg_data, int quality = 80) = 0;
    int width() const { return 240; }
    int height() const { return 240; }
};
