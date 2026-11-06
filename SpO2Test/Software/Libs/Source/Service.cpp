#include "Service.hpp"

#include <cstdarg>
#include <cstdio>
#include <ctime>

#define LOG_MODULE_PRX      "SpO2Test"
#define LOG_MODULE_LEVEL    LOG_LEVEL_INFO
#include "SDK/UnaLogger/Logger.h"

#include "SDK/Kernel/KernelProviderService.hpp"
#include "SDK/SensorLayer/DataParsers/SensorDataParserSpo2.hpp"
#include "SDK/Messages/CommandMessages.hpp"
#include "SDK/Messages/SensorLayerMessages.hpp"
#include "SDK/Messages/MessageGuard.hpp"

Service::Service(SDK::Kernel &kernel)
    : mKernel(kernel)
    , mGlanceUI()
    , mTitle()
    , mValue()
    , mStatus()
    , mSensor(SDK::Sensor::Type::SPO2)
    , mState(State::WAITING)
    , mStartMs(0)
    , mSamples(0)
    , mSaturationTenths(0)
    , mTrustTenths(0)
{
}

Service::~Service()
{
    stop();
}

void Service::run()
{
    LOG_INFO("Started\n");

    while (true) {
        SDK::MessageBase *msg;

        if (!mKernel.comm.getMessage(msg)) {
            continue;
        }

        switch (msg->getType()) {

            case SDK::MessageType::EVENT_GLANCE_START:
                if (configGui()) {
                    createGuiControls();
                    start();
                } else {
                    mKernel.comm.releaseMessage(msg);
                    mKernel.sys.exit(0); // no return
                }
                break;

            case SDK::MessageType::COMMAND_APP_STOP:
            case SDK::MessageType::EVENT_GLANCE_STOP:
                stop();
                // Last event: release it before leaving.
                mKernel.comm.releaseMessage(msg);
                return;

            case SDK::MessageType::EVENT_GLANCE_TICK:
                onGlanceTick();
                break;

            case SDK::MessageType::EVENT_SENSOR_LAYER_DATA: {
                auto event = static_cast<SDK::Message::Sensor::EventData*>(msg);
                SDK::Sensor::DataBatch batch(event->data, event->count, event->stride);
                handleSensorsData(event->handle, batch);
                } break;

            default:
                break;
        }

        mKernel.comm.releaseMessage(msg);
    }
}

void Service::start()
{
    mStartMs = mKernel.sys.getTimeMs();
    mSamples = 0;

    const bool connected = mSensor.connect();
    const bool resolved  = mSensor.isValid();
    mState = connected ? State::WAITING : State::NO_SENSOR;

    log("start: driver %s, connect %s",
        resolved ? "found" : "not found",
        connected ? "ok" : "failed");
    refresh();
}

void Service::stop()
{
    if (mSensor.isConnected()) {
        mSensor.disconnect();
        const uint32_t secs = (mKernel.sys.getTimeMs() - mStartMs) / 1000;
        log("stop: %lu samples in %lu s",
            static_cast<unsigned long>(mSamples), static_cast<unsigned long>(secs));
    }
}

void Service::handleSensorsData(uint16_t handle, SDK::Sensor::DataBatch& data)
{
    if (!mSensor.matchesDriver(handle)) {
        return;
    }

    for (uint16_t i = 0; i < data.size(); ++i) {
        SDK::SensorDataParser::Spo2 p(data[i]);
        mSamples++;

        if (!p.isDataValid()) {
            log("sample %lu: %u fields, expected 2",
                static_cast<unsigned long>(mSamples),
                static_cast<unsigned>(data[i].getFieldCount()));
            continue;
        }

        const float sat   = p.getSaturation();
        const float trust = p.getTrustLevel();
        mSaturationTenths = sat   > 0.f ? static_cast<uint32_t>(sat * 10.f + 0.5f)   : 0;
        mTrustTenths      = trust > 0.f ? static_cast<uint32_t>(trust * 10.f + 0.5f) : 0;
        mState = State::READING;

        log("sample %lu: %lu.%lu %%, trust %lu.%lu",
            static_cast<unsigned long>(mSamples),
            static_cast<unsigned long>(mSaturationTenths / 10),
            static_cast<unsigned long>(mSaturationTenths % 10),
            static_cast<unsigned long>(mTrustTenths / 10),
            static_cast<unsigned long>(mTrustTenths % 10));
    }

    refresh();
}

void Service::onGlanceTick()
{
    refresh();

    if (mGlanceUI.isInvalid()) {
        if (auto upd = SDK::make_msg<SDK::Message::RequestGlanceUpdate>(mKernel)) {
            upd->name           = APP_NAME;
            upd->controls       = mGlanceUI.data();
            upd->controlsNumber = static_cast<uint32_t>(mGlanceUI.size());
            upd.send(100);
        }
        mGlanceUI.setValid();
    }
}

bool Service::configGui()
{
    if (auto gc = SDK::make_msg<SDK::Message::RequestGlanceConfig>(mKernel)) {
        if (gc.send(100) && gc.ok() && gc->maxControls >= 3) {
            mGlanceUI.setWidth(gc->width);
            mGlanceUI.setHeight(gc->height);
            return true;
        }
    }
    return false;
}

void Service::createGuiControls()
{
    mTitle = mGlanceUI.createText();
    mTitle.pos({ kTitleX, kTitleY }, { kTitleW, kTitleH })
        .font(GlanceFont_t::GLANCE_FONT_POPPINS_SEMIBOLD_20)
        .color(GlanceColor_t::GLANCE_COLOR_TEAL)
        .setText("SpO2 Test")
        .alignment(GlanceAlignH_t::GLANCE_ALIGN_H_CENTER);

    mValue = mGlanceUI.createText();
    mValue.pos({ kValueX, kValueY }, { kValueW, kValueH })
        .font(GlanceFont_t::GLANCE_FONT_POPPINS_SEMIBOLD_30)
        .color(GlanceColor_t::GLANCE_COLOR_WHITE)
        .setText("--")
        .alignment(GlanceAlignH_t::GLANCE_ALIGN_H_RIGHT);

    mStatus = mGlanceUI.createText();
    mStatus.pos({ kStatusX, kStatusY }, { kStatusW, kStatusH })
        .font(GlanceFont_t::GLANCE_FONT_POPPINS_REGULAR_18)
        .color(GlanceColor_t::GLANCE_COLOR_GRAY)
        .setText("")
        .alignment(GlanceAlignH_t::GLANCE_ALIGN_H_LEFT);
}

void Service::refresh()
{
    const uint32_t secs = (mKernel.sys.getTimeMs() - mStartMs) / 1000;

    switch (mState) {
        case State::NO_SENSOR:
            mValue.setText("--");
            mStatus.setText("No sensor");
            break;

        case State::WAITING:
            mValue.setText("--");
            if (secs * 1000 >= kNoDataAfterMs) {
                mStatus.setText("No data");
            } else {
                mStatus.print("Wait %lus", static_cast<unsigned long>(secs));
            }
            break;

        case State::READING:
            if (mSaturationTenths > 0) {
                mValue.print("%lu%%", static_cast<unsigned long>((mSaturationTenths + 5) / 10));
            } else {
                mValue.setText("--");
            }
            mStatus.print("trust %lu.%lu", static_cast<unsigned long>(mTrustTenths / 10),
                                           static_cast<unsigned long>(mTrustTenths % 10));
            break;
    }
}

void Service::log(const char* fmt, ...)
{
    char line[128];
    const std::time_t now = std::time(nullptr);
    int n = snprintf(line, sizeof(line), "%lld ", static_cast<long long>(now));

    va_list args;
    va_start(args, fmt);
    n += vsnprintf(line + n, sizeof(line) - n - 1, fmt, args);
    va_end(args);
    if (n > static_cast<int>(sizeof(line)) - 2) {
        n = sizeof(line) - 2;
    }
    line[n++] = '\n';

    LOG_INFO("%.*s", n, line);

    auto file = mKernel.fs.file(skLogPath);
    if (!file || !file->open(true, false)) {
        return;
    }
    size_t written = 0;
    file->seek(file->size());
    file->write(line, static_cast<size_t>(n), written);
    file->close();
}
