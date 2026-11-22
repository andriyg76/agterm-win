#include "WebView2Shim.h"

#include <windows.h>
#include <wrl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>

#include "WebView2.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> webview;

const wchar_t *wide(const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); }
} // namespace

namespace {
wchar_t crashLog[MAX_PATH];

void crashLine(const char *text) {
    HANDLE file = CreateFileW(crashLog, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(file, text, static_cast<DWORD>(strlen(text)), &written, nullptr);
    CloseHandle(file);
}

LONG WINAPI unhandled(EXCEPTION_POINTERS *info) {
    char line[256];
    HMODULE module = nullptr;
    char name[MAX_PATH] = "?";
    void *address = info->ExceptionRecord->ExceptionAddress;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCSTR>(address), &module)) {
        GetModuleFileNameA(module, name, MAX_PATH);
    }
    snprintf(line, sizeof line, "unhandled exception 0x%08lx at %p (%s+0x%llx) thread %lu\n",
             info->ExceptionRecord->ExceptionCode, address, name,
             static_cast<unsigned long long>(static_cast<char *>(address) - reinterpret_cast<char *>(module)),
             GetCurrentThreadId());
    crashLine(line);
    return EXCEPTION_CONTINUE_SEARCH;
}

void invalidParameter(const wchar_t *, const wchar_t *, const wchar_t *, unsigned int, uintptr_t) {
    char line[96];
    snprintf(line, sizeof line, "UCRT invalid parameter, thread %lu\n", GetCurrentThreadId());
    crashLine(line);
    TerminateProcess(GetCurrentProcess(), 0xC000000D);
}
} // namespace

extern "C" void crash_log_install(const uint16_t *path) {
    wcsncpy_s(crashLog, wide(path), _TRUNCATE);
    SetUnhandledExceptionFilter(unhandled);
    _set_invalid_parameter_handler(invalidParameter);
}

extern "C" void wv_init_process(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}

extern "C" int32_t wv_create(void *hwndRaw, const uint16_t *browserFolder, const uint16_t *userDataFolder, const uint16_t *html,
                             wv_ready_cb ready, wv_message_cb message, void *ctx) {
    HWND hwnd = static_cast<HWND>(hwndRaw);
    std::wstring page(wide(html));
    return CreateCoreWebView2EnvironmentWithOptions(
        browserFolder ? wide(browserFolder) : nullptr, wide(userDataFolder), nullptr,
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
