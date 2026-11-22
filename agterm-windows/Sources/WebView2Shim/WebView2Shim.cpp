#include "WebView2Shim.h"

#include <windows.h>
#include <wrl.h>
#include <string>

#include "WebView2.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> webview;

const wchar_t *wide(const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); }
} // namespace

extern "C" void wv_init_process(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}

extern "C" int32_t wv_create(void *hwndRaw, const uint16_t *userDataFolder, const uint16_t *html,
                             wv_ready_cb ready, wv_message_cb message, void *ctx) {
    HWND hwnd = static_cast<HWND>(hwndRaw);
    std::wstring page(wide(html));
    return CreateCoreWebView2EnvironmentWithOptions(
        nullptr, wide(userDataFolder), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [=](HRESULT result, ICoreWebView2Environment *env) -> HRESULT {
                if (FAILED(result) || !env) {
                    ready(ctx, result);
                    return S_OK;
                }
                return env->CreateCoreWebView2Controller(
                    hwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                              [=](HRESULT result, ICoreWebView2Controller *created) -> HRESULT {
                                  if (FAILED(result) || !created) {
                                      ready(ctx, result);
                                      return S_OK;
                                  }
                                  controller = created;
                                  controller->get_CoreWebView2(&webview);
                                  RECT bounds;
                                  GetClientRect(hwnd, &bounds);
                                  controller->put_Bounds(bounds);
                                  EventRegistrationToken token;
                                  webview->add_WebMessageReceived(
                                      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                          [=](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                                              LPWSTR text = nullptr;
                                              if (SUCCEEDED(args->TryGetWebMessageAsString(&text)) && text) {
                                                  message(ctx, reinterpret_cast<const uint16_t *>(text));
                                                  CoTaskMemFree(text);
                                              }
                                              return S_OK;
                                          })
                                          .Get(),
                                      &token);
                                  webview->NavigateToString(page.c_str());
                                  ready(ctx, S_OK);
                                  return S_OK;
                              })
                              .Get());
            })
            .Get());
}

extern "C" void wv_resize(int32_t width, int32_t height) {
    if (controller) controller->put_Bounds(RECT{0, 0, width, height});
}

extern "C" void wv_focus(void) {
    if (controller) controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
}

extern "C" void wv_post_string(const uint16_t *message) {
    if (webview) webview->PostWebMessageAsString(wide(message));
}
