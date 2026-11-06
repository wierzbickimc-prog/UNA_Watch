#ifndef __SERVICE_HPP__
#define __SERVICE_HPP__

#include <cstdint>

#include "SDK/Kernel/Kernel.hpp"
#include "SDK/Glance/GlanceControl.hpp"
#include "SDK/SensorLayer/SensorConnection.hpp"
#include "SDK/SensorLayer/SensorDataBatch.hpp"

// A glance that asks the watch for SpO2 and shows what comes back, so we can
// tell whether this firmware delivers it. Every event is also appended to
// spo2_log.txt in the app's folder, to read over USB afterwards.
class Service
{
public:
    Service(SDK::Kernel &kernel);
    virtual ~Service();

    void run();

private:
    enum class State {
        NO_SENSOR,  // the kernel has no SpO2 driver, or refused the connection
        WAITING,    // connected, nothing received yet
        READING,    // at least one sample arrived
    };

    void start();
    void stop();
    void handleSensorsData(uint16_t handle, SDK::Sensor::DataBatch& data);
    void onGlanceTick();
    bool configGui();
    void createGuiControls();
    void refresh();
    void log(const char* fmt, ...);

    static constexpr int16_t kTitleX  = 18;
    static constexpr int16_t kTitleY  = 0;
    static constexpr int16_t kTitleW  = 205;
    static constexpr int16_t kTitleH  = 30;

    static constexpr int16_t kValueX  = 15;
    static constexpr int16_t kValueY  = 28;
    static constexpr int16_t kValueW  = 100;
    static constexpr int16_t kValueH  = 40;

    static constexpr int16_t kStatusX = 115;
    static constexpr int16_t kStatusY = 36;
    static constexpr int16_t kStatusW = 115;
    static constexpr int16_t kStatusH = 28;

    // Give up waiting after this long and say so.
    static constexpr uint32_t kNoDataAfterMs = 90000;

    static constexpr char skLogPath[] = "spo2_log.txt";

    const SDK::Kernel&        mKernel;
    SDK::Glance::Form         mGlanceUI;
    SDK::Glance::ControlText  mTitle;
    SDK::Glance::ControlText  mValue;
    SDK::Glance::ControlText  mStatus;

    SDK::Sensor::Connection mSensor;
    State                   mState;
    uint32_t                mStartMs;
    uint32_t                mSamples;
    uint32_t                mSaturationTenths;
    uint32_t                mTrustTenths;
};

#endif
