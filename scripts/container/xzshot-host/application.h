#pragma once
class Application {
public:
    static Application& GetInstance() { static Application a; return a; }
    int GetDeviceState() const { return 3; }
};
