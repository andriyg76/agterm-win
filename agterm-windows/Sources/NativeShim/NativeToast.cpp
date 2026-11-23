#include "NativeShim.h"

#include <windows.h>
#include <appmodel.h>
#include <shobjidl.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <wchar.h>

// Windows toasts through the WinRT ABI, which needs no C++/WinRT projection. A packaged build has the identity
// toasts need; an unpackaged one names its AppUserModelID, which the caller registers.

using namespace ABI::Windows::UI::Notifications;
using namespace ABI::Windows::Data::Xml::Dom;

namespace {

template <typename T> struct Ref {
    T *pointer = nullptr;
    Ref() = default;
    Ref(const Ref &) = delete;
    Ref &operator=(const Ref &) = delete;
    ~Ref() {
        if (pointer) pointer->Release();
    }
    T **put() { return &pointer; }
    void **raw() { return reinterpret_cast<void **>(&pointer); }
    T *operator->() const { return pointer; }
    explicit operator bool() const { return pointer != nullptr; }
};

struct String {
    HSTRING value = nullptr;
    explicit String(const wchar_t *text) {
        WindowsCreateString(text, text ? static_cast<UINT32>(wcslen(text)) : 0, &value);
    }
    String(const String &) = delete;
    String &operator=(const String &) = delete;
    ~String() { WindowsDeleteString(value); }
};

HWND target = nullptr;
UINT activatedMessage = 0;
wchar_t appID[128] = L"";
bool packaged = false;
IToastNotifier *notifier = nullptr;  // kept for the process

using ActivatedHandler = ABI::Windows::Foundation::ITypedEventHandler<ToastNotification *, IInspectable *>;

// Activated runs on a WinRT thread: it copies the toast's group, a session id, onto the heap and posts it to the
// window, which frees it with nt_toast_free.
struct Activated : ActivatedHandler {
    LONG references = 1;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IAgileObject) || iid == __uuidof(ActivatedHandler)) {
            *object = static_cast<ActivatedHandler *>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG left = InterlockedDecrement(&references);
        if (left == 0) delete this;
        return left;
    }
    HRESULT STDMETHODCALLTYPE Invoke(IToastNotification *sender, IInspectable *) override {
        Ref<IToastNotification2> tagged;
        HSTRING group = nullptr;
        if (!sender || FAILED(sender->QueryInterface(__uuidof(IToastNotification2), tagged.raw())) || FAILED(tagged->get_Group(&group))) {
            return S_OK;
        }
        UINT32 length = 0;
        const wchar_t *text = WindowsGetStringRawBuffer(group, &length);
        auto copy = static_cast<wchar_t *>(calloc(length + 1, sizeof(wchar_t)));
        if (copy) {
            memcpy(copy, text, length * sizeof(wchar_t));
            if (!PostMessageW(target, activatedMessage, 0, reinterpret_cast<LPARAM>(copy))) free(copy);
        }
        WindowsDeleteString(group);
        return S_OK;
    }
};

template <typename T> bool factory(const wchar_t *runtimeClass, Ref<T> &out) {
    String name(runtimeClass);
    return SUCCEEDED(RoGetActivationFactory(name.value, __uuidof(T), out.raw()));
}

}  // namespace

extern "C" int32_t nt_is_packaged(void) {
    UINT32 length = 0;
    return GetCurrentPackageFullName(&length, nullptr) != APPMODEL_ERROR_NO_PACKAGE;
}

extern "C" int32_t nt_toast_init(void *window, uint32_t message, const uint16_t *app_id, const uint16_t *display_name,
                                 const uint16_t *icon) {
    target = static_cast<HWND>(window);
    activatedMessage = message;
    wcsncpy_s(appID, reinterpret_cast<const wchar_t *>(app_id), _TRUNCATE);
    packaged = nt_is_packaged() != 0;
    if (!packaged) {
        // the key Windows reads an unpackaged sender's name and icon from, so no Start menu shortcut is needed
        wchar_t key[192];
        swprintf_s(key, L"Software\\Classes\\AppUserModelId\\%ls", appID);
        auto name = reinterpret_cast<const wchar_t *>(display_name), path = reinterpret_cast<const wchar_t *>(icon);
        RegSetKeyValueW(HKEY_CURRENT_USER, key, L"DisplayName", REG_SZ, name, static_cast<DWORD>((wcslen(name) + 1) * sizeof(wchar_t)));
        if (path && *path) {
            RegSetKeyValueW(HKEY_CURRENT_USER, key, L"IconUri", REG_SZ, path, static_cast<DWORD>((wcslen(path) + 1) * sizeof(wchar_t)));
        }
        SetCurrentProcessExplicitAppUserModelID(appID);
    }
    RoInitialize(RO_INIT_SINGLETHREADED);  // already initialized either way is fine
    Ref<IToastNotificationManagerStatics> statics;
    if (!factory(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager, statics)) return 0;
    HRESULT created;
    if (packaged) {
        created = statics->CreateToastNotifier(&notifier);
    } else {
        String id(appID);
        created = statics->CreateToastNotifierWithId(id.value, &notifier);
    }
    return SUCCEEDED(created);
}

extern "C" int32_t nt_toast_show(const uint16_t *xml, const uint16_t *tag, const uint16_t *group) {
    if (!notifier) return 0;
    Ref<IInspectable> instance;
    Ref<IXmlDocument> document;
    Ref<IXmlDocumentIO> loader;
    Ref<IToastNotificationFactory> toasts;
    Ref<IToastNotification> toast;
    Ref<IToastNotification2> tagged;
    String documentClass(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument), content(reinterpret_cast<const wchar_t *>(xml));
    if (FAILED(RoActivateInstance(documentClass.value, instance.put())) ||
        FAILED(instance->QueryInterface(__uuidof(IXmlDocument), document.raw())) ||
        FAILED(document->QueryInterface(__uuidof(IXmlDocumentIO), loader.raw())) || FAILED(loader->LoadXml(content.value)) ||
        !factory(RuntimeClass_Windows_UI_Notifications_ToastNotification, toasts) ||
        FAILED(toasts->CreateToastNotification(document.pointer, toast.put())) ||
        FAILED(toast->QueryInterface(__uuidof(IToastNotification2), tagged.raw()))) {
        return 0;
    }
    // one toast per tag and group: a later one replaces it, as a repeated macOS banner does
    String tagName(reinterpret_cast<const wchar_t *>(tag)), groupName(reinterpret_cast<const wchar_t *>(group));
    tagged->put_Tag(tagName.value);
    tagged->put_Group(groupName.value);
    auto handler = new Activated();
    EventRegistrationToken token{};
    toast->add_Activated(handler, &token);
    handler->Release();
    return SUCCEEDED(notifier->Show(toast.pointer));
}

extern "C" void nt_toast_remove_group(const uint16_t *group) {
    Ref<IToastNotificationManagerStatics2> statics;
    Ref<IToastNotificationHistory> history;
    if (!notifier || !factory(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager, statics) ||
        FAILED(statics->get_History(history.put()))) {
        return;
    }
    String name(reinterpret_cast<const wchar_t *>(group));
    if (packaged) {
        history->RemoveGroup(name.value);
    } else {
        String id(appID);
        history->RemoveGroupWithId(name.value, id.value);
    }
}

extern "C" void nt_toast_free(void *text) { free(text); }
