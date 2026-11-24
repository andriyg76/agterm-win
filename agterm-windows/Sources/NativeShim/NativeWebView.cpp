#include "NativeShim.h"

#include <WebView2.h>
#include <wrl.h>

#include <shlwapi.h>
#include <stdio.h>
#include <string>
#include <unordered_map>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kPageSetup = WM_APP + 40;

struct PageView {
  HWND parent = nullptr;
  HWND host = nullptr;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> web;
  int32_t state = 0; // 0 loading, 1 loaded, 2 failed
  std::wstring error;
  std::wstring title;
  std::wstring pendingPath;
  std::wstring pendingUrl;
  bool pendingFile = false;
};

std::unordered_map<HWND, PageView *> pages;
PageView *pageOf(HWND host) {
  auto it = pages.find(host);
  return it == pages.end() ? nullptr : it->second;
}

LRESULT CALLBACK pageHostProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == kPageSetup) {
    PageView *view = pageOf(hwnd);
    if (!view) return DefWindowProcW(hwnd, msg, wParam, lParam);
    auto envHandler = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [view](HRESULT result, ICoreWebView2Environment *env) -> HRESULT {
          if (FAILED(result) || !env) {
            view->state = 2;
            view->error = L"WebView2 environment failed";
            return result;
          }
          return env->CreateCoreWebView2Controller(
              view->host,
              Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                  [view](HRESULT result, ICoreWebView2Controller *controller) -> HRESULT {
                    if (FAILED(result) || !controller) {
                      view->state = 2;
                      view->error = L"WebView2 controller failed";
                      return result;
                    }
                    view->controller = controller;
                    ComPtr<ICoreWebView2> web;
                    controller->get_CoreWebView2(&web);
                    view->web = web;
                    controller->put_IsVisible(TRUE);
                    RECT bounds{0, 0, 0, 0};
                    GetClientRect(view->host, &bounds);
                    if (bounds.right < 1) bounds.right = 1;
                    if (bounds.bottom < 1) bounds.bottom = 1;
                    controller->put_Bounds(bounds);
                    EventRegistrationToken navToken{};
                    web->add_NavigationCompleted(
                        Callback<ICoreWebView2NavigationCompletedEventHandler>(
                            [view](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                              BOOL success = FALSE;
                              args->get_IsSuccess(&success);
                              if (success) {
                                view->state = 1;
                                view->error.clear();
                                PWSTR title = nullptr;
                                view->web->get_DocumentTitle(&title);
                                if (title) {
                                  view->title = title;
                                  CoTaskMemFree(title);
                                }
                              } else {
                                view->state = 2;
                                view->error = L"navigation failed";
                              }
                              return S_OK;
                            })
                            .Get(),
                        &navToken);
                    if (view->pendingFile && !view->pendingPath.empty()) {
                      std::wstring uri = L"file:///" + view->pendingPath;
                      for (wchar_t &c : uri) {
                        if (c == L'\\') c = L'/';
                      }
                      view->web->Navigate(uri.c_str());
                    } else if (!view->pendingUrl.empty()) {
                      view->web->Navigate(view->pendingUrl.c_str());
                    }
                    return S_OK;
                  })
                  .Get());
        });
    CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr, envHandler.Get());
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void ensureHostClass() {
  static bool registered = false;
  if (registered) return;
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = pageHostProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"agterm-page";
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  RegisterClassExW(&wc);
  registered = true;
}

} // namespace

extern "C" void *nt_page_create(void *parent) {
  ensureHostClass();
  HWND parentHwnd = static_cast<HWND>(parent);
  HWND host = CreateWindowExW(WS_EX_NOPARENTNOTIFY, L"agterm-page", nullptr,
                              WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 1, 1, parentHwnd, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
  if (!host) return nullptr;
  auto *view = new PageView();
  view->parent = parentHwnd;
  view->host = host;
  pages[host] = view;
  PostMessageW(host, kPageSetup, 0, 0);
  return host;
}

extern "C" void nt_page_destroy(void *page) {
  HWND host = static_cast<HWND>(page);
  PageView *view = pageOf(host);
  if (view) {
    if (view->controller) view->controller->Close();
    delete view;
    pages.erase(host);
  }
  DestroyWindow(host);
}

extern "C" void nt_page_move(void *page, int32_t x, int32_t y, int32_t width, int32_t height) {
  HWND host = static_cast<HWND>(page);
  SetWindowPos(host, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
  PageView *view = pageOf(host);
  if (view && view->controller) {
    RECT bounds{0, 0, width, height};
    view->controller->put_Bounds(bounds);
  }
}

extern "C" void nt_page_navigate_file(void *page, const uint16_t *path) {
  HWND host = static_cast<HWND>(page);
  PageView *view = pageOf(host);
  if (!view || !path) return;
  view->pendingFile = true;
  view->pendingPath = reinterpret_cast<const wchar_t *>(path);
  view->pendingUrl.clear();
  view->state = 0;
  if (view->web) {
    std::wstring uri = L"file:///" + view->pendingPath;
    for (wchar_t &c : uri) {
      if (c == L'\\') c = L'/';
    }
    view->web->Navigate(uri.c_str());
  }
}

extern "C" void nt_page_navigate_html(void *page, const uint16_t *html) {
  HWND host = static_cast<HWND>(page);
  PageView *view = pageOf(host);
  if (!view || !html) return;
  view->state = 0;
  if (view->web) {
    view->web->NavigateToString(reinterpret_cast<const wchar_t *>(html));
  }
}

extern "C" void nt_page_navigate_url(void *page, const uint16_t *url) {
  HWND host = static_cast<HWND>(page);
  PageView *view = pageOf(host);
  if (!view || !url) return;
  view->pendingFile = false;
  view->pendingUrl = reinterpret_cast<const wchar_t *>(url);
  view->state = 0;
  if (view->web) view->web->Navigate(view->pendingUrl.c_str());
}

extern "C" int32_t nt_page_state(void *page) {
  PageView *view = pageOf(static_cast<HWND>(page));
  return view ? view->state : 2;
}

extern "C" int32_t nt_page_title(void *page, uint16_t *out, int32_t capacity) {
  PageView *view = pageOf(static_cast<HWND>(page));
  if (!view || capacity <= 0) return 0;
  const std::wstring &title = view->title;
  int32_t length = static_cast<int32_t>(title.size());
  if (out && length < capacity) {
    memcpy(out, title.c_str(), static_cast<size_t>(length + 1) * sizeof(wchar_t));
  }
  return length;
}