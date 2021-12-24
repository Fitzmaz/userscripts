// store all active context menu items here
// this var will be referenced to determine the removal of the context menu click event handler
// it'll also be used to know if a specific url already has active context menu items
let contextMenuItems = [];
let platformGlobal;
let xhrs = [];

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    // content script listening seems to be the most reliable way to trigger injection
    const name = request.name;
    if (name === "REQ_USERSCRIPTS") {
        const url = sender.url;
        // use frameId to determine if request came from top level window
        const isTop = sender.frameId === 0 ? true : false;
        // ask swift layer to provide code for current url(s)
        const message = {name: name, url: url, isTop: isTop};
        browser.runtime.sendNativeMessage(message, response => {
            // send code back to content script for parsing and injection
            // could use tabs.executeScript(sender.tab.id) for content context injection
            // but for now, will rely on eval() in content script
            const code = response.code;
            sendResponse({code: code});
            // update badge count on injection
            // especially useful when injection is deferred (ie. subframes)
            setBadgeCount();
        });
        // https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/runtime/onMessage#sending_an_asynchronous_response_using_sendresponse
        return true;
    } else if (name === "CONTEXT_CREATE") {
        const menuItemId = request.menuItemId;
        const menuObj = {
            contexts: ["all"],
            documentUrlPatterns: [request.url],
            id: menuItemId,
            title: request.title,
        };
        const onCreate = () => {
            if (browser.runtime.lastError) {
                console.error(browser.runtime.lastError);
            } else {
                sendResponse({menuItemId: menuItemId});
                contextMenuItems.push(menuItemId);
                // only add listener if not already attached
                if (!browser.menus.onClicked.hasListener(contextClick)) {
                    browser.menus.onClicked.addListener(contextClick);
                }
            }
        };
        // first check if the context menu item is already present for a tab on the same url
        // if so, remove the current context menu item & entry in context menu items array
        // although already created context menu items automatically apply
        // to subsequent tab urls that match the documentUrlPatterns supplied at creation
        // the user could have edited the userscript since the first application
        if (contextMenuItems.includes(menuItemId)) {
            browser.contextMenus.remove(menuItemId, () => {
                contextMenuItems = contextMenuItems.filter(a => a !== menuItemId);
                browser.contextMenus.create(menuObj, onCreate);
            });
        } else {
            browser.contextMenus.create(menuObj, onCreate);
        }
        return true;
    } else if (name === "CONTEXT_REMOVE") {
        // tab closes events dispatch remove request with a menuItemId
        // remove the context menu item associated with the menuItemId when that event comes in
        // if tabs with the same url exist, the context menu item will be recreated on right click
        const menuItemId = request.menuItemId;
        browser.contextMenus.remove(menuItemId, () => {
            contextMenuItems = contextMenuItems.filter(a => a !== menuItemId);
            purgeContextMenus();
        });
    } else if (name === "API_OPEN_TAB") {
        const active = (request.active === true) ? true : false;
        browser.tabs.create({active: active, index: sender.tab.index + 1, url: request.url}, response => {
            sendResponse(response);
        });
        return true;
    } else if (name === "API_CLOSE_TAB") {
        browser.tabs.remove(sender.tab.id, response => {/* */});
    } else if (name === "API_SET_VALUE") {
        const item = {};
        item[request.filename + "---" + request.key] = request.value;
        browser.storage.local.set(item, response => {
            sendResponse({success: true});
        });
        return true;
    } else if (name === "API_GET_VALUE") {
        const key = request.filename + "---" + request.key;
        browser.storage.local.get(key, item => {
            if (Object.keys(item).length === 0 && request.defaultValue) {
                sendResponse(request.defaultValue);
            } else {
                sendResponse(Object.values(item)[0]);
            }
        });
        return true;
    } else if (name === "API_DELETE_VALUE") {
        const key = request.filename + "---" + request.key;
        browser.storage.local.remove(key, response => {
            sendResponse({success: true});
        });
        return true;
    } else if (name === "API_LIST_VALUES") {
        const prefix = request.filename + "---";
        const keys = [];
        browser.storage.local.get().then(items => {
            for (const key in items) {
                if (key.startsWith(prefix)) {
                    const k = key.replace(prefix, "");
                    keys.push(k);
                }
            }
            sendResponse(keys);
        });
        return true;
    } else if (name === "REQ_PLATFORM") {
        (async () => {
            try {
                const p = await getPlatform();
                sendResponse({platform: p});
            } catch (error) {
                console.error(error);
                sendResponse({error: "Couldn't get platform"});
            }
        })();
        return true;
    } else if (name === "API_XHR_CS") {
        // https://jsonplaceholder.typicode.com/posts
        // get tab id and respond only to the content script that sent message
        const tab = sender.tab.id;
        const details = request.details;
        const method = details.method ? details.method : "GET";
        const user = details.user || null;
        const password = details.password || null;
        let body = details.data || null;
        if (body && details.binary) body = new Blob([body], {type: "text/plain"});
        const xhr = new XMLHttpRequest();
        // push to global scoped array so it can be aborted
        xhrs.push({xhr: xhr, xhrId: request.xhrId});
        xhr.withCredentials = (details.user && details.password);
        xhr.timeout = details.timeout || 0;
        if (details.overrideMimeType) xhr.overrideMimeType(details.overrideMimeType);
        xhrAddListeners(xhr, tab, request.xhrId, details);
        xhr.open(method, details.url, true, user, password);
        xhr.responseType = details.responseType || "";
        if (details.headers) {
            for (const key in details.headers) {
                const val = details.headers[key];
                xhr.setRequestHeader(key, val);
            }
        }
        xhr.send(body);
        // remove xhr from global scope when completed
        xhr.onloadend = progressEvent => xhrs = xhrs.filter(x => x.xhrId !== request.xhrId);
        // sendResponse({details: details});
    } else if (name === "API_XHR_ABORT_CS") {
        // get the xhrId from request
        const xhrId = request.xhrId;
        const match = xhrs.find(x => x.xhrId === xhrId);
        if (match) {
            match.xhr.abort();
            // sendResponse(match);
        } else {
            console.log(`abort message recieved for ${xhrId}, but it couldn't be found`);
        }
    } else if (["USERSCRIPT_INSTALL_00", "USERSCRIPT_INSTALL_01", "USERSCRIPT_INSTALL_02"].includes(name)) {
        const message = {name: name, content: request.content};
        browser.runtime.sendNativeMessage(message, response => {
            sendResponse(response);
        });
        return true;
    } else if (name === "POLL_LOG") {
        browser.runtime.sendNativeMessage({name: "POLL_LOG"}, response => {
            sendResponse(response);
        });
        return true;
    }
});

function xhrHandleEvent(e, xhr, tab, xhrId) {
    const name = `RESP_API_XHR_BG_${e.type.toUpperCase()}`;
    const x = {
        readyState: xhr.readyState,
        response: xhr.response,
        responseHeaders: xhr.getAllResponseHeaders(),
        responseType: xhr.responseType,
        responseURL: xhr.responseURL,
        status: xhr.status,
        statusText: xhr.statusText,
        timeout: xhr.timeout,
        withCredentials: xhr.withCredentials
    };
    // only include responseText when applicable
    if (["", "text"].includes(xhr.responseType)) x.responseText = xhr.responseText;
    browser.tabs.sendMessage(tab, {name: name, xhrId: xhrId, response: x});
}

function xhrAddListeners(xhr, tab, xhrId, details) {
    if (details.onabort) {
        xhr.addEventListener("abort", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.onerror) {
        xhr.addEventListener("error", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.onload) {
        xhr.addEventListener("load", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.onloadend) {
        xhr.addEventListener("loadend", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.onloadstart) {
        xhr.addEventListener("loadstart", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.onprogress) {
        xhr.addEventListener("progress", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.onreadystatechange) {
        xhr.addEventListener("readystatechange", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
    if (details.ontimeout) {
        xhr.addEventListener("timeout", e => xhrHandleEvent(e, xhr, tab, xhrId));
    }
}

function contextClick(info, tab) {
    browser.tabs.query({currentWindow: true, active: true}, tabs => {
        browser.tabs.sendMessage(tabs[0].id, {name: "CONTEXT_RUN", menuItemId: info.menuItemId});
    });
}

function purgeContextMenus() {
    // loop through all tabs and remove context menu items targeting tab urls that don't exist
    browser.tabs.query({}, tabs => {
        const tabUrls = [];
        tabs.forEach(tab => {if (tab.url) tabUrls.push(tab.url);});
        const contextMenuItemsUrls = [];
        // parse urls from context menu item ids
        contextMenuItems.forEach(item => contextMenuItemsUrls.push(item.split("&$&")[0]));
        // get content menu items targeting urls not in tabUrls
        const staleUrls = contextMenuItemsUrls.filter(a => !tabUrls.includes(a));
        // remove stale elements from context menu item array & remove menu item
        staleUrls.forEach(staleUrl => {
            contextMenuItems.forEach(contextMenuItem => {
                if (contextMenuItem.includes(staleUrl)) {
                    contextMenuItems.splice(contextMenuItems.indexOf(contextMenuItem), 1);
                    browser.contextMenus.remove(contextMenuItem);
                }
            });
        });
        // if there are no more context menu items in array remove the event listener
        browser.menus.onClicked.removeListener(contextClick);
        // remove any lingering context menu items
        browser.contextMenus.removeAll();
    });
}

async function setBadgeCount() {
    // only set badge on macOS
    const platform = await getPlatform();
    if (platform !== "macos") return;

    const tabs = await new Promise(resolve => {
        browser.tabs.query({currentWindow: true, active: true}, tabs => {
            resolve(tabs);
        });
    });
    if (!tabs) return;
    const url = tabs[0].url;
    const message = {name: "POPUP_BADGE_COUNT", url: url, frameUrls: []};
    if (url) {
        const frames = await new Promise(resolve => {
            browser.webNavigation.getAllFrames({tabId: tabs[0].id}, frames => {
                resolve(frames);
            });
        });
        frames.forEach(frame => message.frameUrls.push(frame.url));
    }
    browser.runtime.sendNativeMessage(message, response => {
        if (response.error) return console.error(response.error);
        const count = response.count;
        if (count > 0) {
            browser.browserAction.setBadgeText({text: count.toString()});
        } else {
            browser.browserAction.setBadgeText({text: ""});
        }
    });
}

async function getPlatform() {
    if (platformGlobal) return platformGlobal;
    const response = await browser.runtime.sendNativeMessage({name: "REQ_PLATFORM"});
    if (!response.platform) {
        console.error("Failed to get platform");
        return "";
    }
    platformGlobal = response.platform;
    return response.platform;
}

browser.tabs.onActivated.addListener(setBadgeCount);
browser.windows.onFocusChanged.addListener(setBadgeCount);
browser.webNavigation.onCompleted.addListener(setBadgeCount);
