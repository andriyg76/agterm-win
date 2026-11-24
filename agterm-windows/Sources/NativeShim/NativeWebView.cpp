#include "NativeShim.h"

#include "../../vendor/webview2/include/WebView2.h"
#include <wrl.h>

#include <shlwapi.h>
#include <stdio.h>
#include <string.h>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr UINT kPageSetup = WM_APP + 40;
constexpr int kMaxPages = 32;

struct PageView {
  HWND parent = nullptr;
  HWND host = nullptr;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> web;
  int32_t state = 0; // 0 loading, 1 loaded, 2 failed
  wchar_t error[256]{};
  wchar_t title[512]{};
  wchar_t pendingPath[MAX_PATH]{};
  wchar_t pendingUrl[2048]{};
  bool pendingFile = false;
};

PageView *g_pages[kMaxPages]{};
HWND g_pageHosts[kMaxPages]{};

PageView *pageOf(HWND host) {
  for (int i = 0; i < kMaxPages; ++i) {
    if (g_pageHosts[i] == host) return g_pages[i];
  }
  return nullptr;
}

bool reservePage(HWND host, PageView *view) {
  for (int i = 0; i < kMaxPages; ++i) {
    if (g_pageHosts[i] == nullptr) {
      g_pageHosts[i] = host;
      g_pages[i] = view;
      return true;
    }
  }
  return false;
}

void releasePage(HWND host) {
  for (int i = 0; i < kMaxPages; ++i) {
    if (g_pageHosts[i] == host) {
      g_pageHosts[i] = nullptr;
      g_pages[i] = nullptr;
      return;
    }
  }
}

void fileUri(wchar_t *out, size_t outChars, const wchar_t *path) {
  if (outChars < 9) return;
  wcscpy_s(out, outChars, L"file:///");
  size_t used = wcslen(out);
  if (used + 1 >= outChars) return;
  wcscpy_s(out + used, outChars - used, path);
  for (wchar_t *c = out; *c; ++c) {
    if (*c == L'\\') *c = L'/';
  }
}

LRESULT CALLBACK pageHostProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == kPageSetup) {
    PageView *view = pageOf(hwnd);
    if (!view) return DefWindowProcW(hwnd, msg, wParam, lParam);
    auto envHandler = Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [view](HRESULT result, ICoreWebView2Environment *env) -> HRESULT {
          if (FAILED(result) || !env) {
            view->state = 2;
            wcscpy_s(view->error, L"WebView2 environment failed");
            return result;
          }
          return env->CreateCoreWebView2Controller(
              view->host,
              Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                  [view](HRESULT result, ICoreWebView2Controller *controller) -> HRESULT {
                    if (FAILED(result) || !controller) {
                      view->state = 2;
                      wcscpy_s(view->error, L"WebView2 controller failed");
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
                                view->error[0] = 0;
                                PWSTR title = nullptr;
                                view->web->get_DocumentTitle(&title);
                                if (title) {
                                  wcscpy_s(view->title, title);
                                  CoTaskMemFree(title);
                                }
                              } else {
                                view->state = 2;
                                wcscpy_s(view->error, L"navigation failed");
                              }
                              return S_OK;
                            })
                            .Get(),
                        &navToken);
                    if (view->pendingFile && view->pendingPath[0]) {
                      wchar_t uri[MAX_PATH + 16];
                      fileUri(uri, sizeof(uri) / sizeof(uri[0]), view->pendingPath);
                      view->web->Navigate(uri);
                    } else if (view->pendingUrl[0]) {
                      view->web->Navigate(view->pendingUrl);
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
  wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
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
  if (!reservePage(host, view)) {
    delete view;
    DestroyWindow(host);
    return nullptr;
  }
  PostMessageW(host, kPageSetup, 0, 0);
  return host;
}

extern "C" void nt_page_destroy(void *page) {
  HWND host = static_cast<HWND>(page);
  PageView *view = pageOf(host);
  if (view) {
    if (view->controller) view->controller->Close();
    delete view;
    releasePage(host);
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
  wcscpy_s(view->pendingPath, reinterpret_cast<const wchar_t *>(path));
  view->pendingUrl[0] = 0;
  view->state = 0;
  if (view->web) {
    wchar_t uri[MAX_PATH + 16];
    fileUri(uri, sizeof(uri) / sizeof(uri[0]), view->pendingPath);
    view->web->Navigate(uri);
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
  wcscpy_s(view->pendingUrl, reinterpret_cast<const wchar_t *>(url));
  view->state = 0;
  if (view->web) view->web->Navigate(view->pendingUrl);
}

extern "C" int32_t nt_page_state(void *page) {
  PageView *view = pageOf(static_cast<HWND>(page));
  return view ? view->state : 2;
}

extern "C" int32_t nt_page_title(void *page, uint16_t *out, int32_t capacity) {
  PageView *view = pageOf(static_cast<HWND>(page));
  if (!view || capacity <= 0) return 0;
  const wchar_t *title = view->title;
  int32_t length = static_cast<int32_t>(wcslen(title));
  if (out && length < capacity) {
    memcpy(out, title, static_cast<size_t>(length + 1) * sizeof(wchar_t));
  }
  return length;
}