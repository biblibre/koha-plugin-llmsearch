$(document).ready(function() {
    $('form#searchform div:first').append('<div class="order-6 order-sm-4 col-sm-auto"><button class="btn btn-primary" type="button" onclick="openForm()" title="AI Chat" aria-label="AI Chat"><i class="fa-solid fa-robot"></i></button></div>');
    
    fetch('/api/v1/contrib/llmsearch/static/chat.html')
        .then(response => response.text())
        .then(html => {
            $('body').append(html);
	    populateChat();
            $('form.chat-container').on('submit', function(event) {
                event.preventDefault();
                askAI();
            });
            // Auto-open chat when the page was reached via an LLM-generated search link
            if (new URLSearchParams(window.location.search).get('llm') === '1') {
                openForm();
            }
        })
        .catch(error => {
            console.error('Error fetching the HTML file:', error);
        });
});

function openForm() {
  document.getElementById("llm-chat").style.display = "block";
}

function closeForm() {
  document.getElementById("llm-chat").style.display = "none";
}

function askAI() {
    var chatInput = $('div#llm-chat input');
    var inputValue = chatInput.val();
    var chatWindow = $('div.chat-messages');
    addMessage('user', inputValue);
    chatInput.val('');

    addMessage('assistant', '<div class="loading-dots"><span>.</span><span>.</span><span>.</span></div>', 0);

    chatWindow.scrollTop(chatWindow[0].scrollHeight);
    
    $.ajax({
        url: '/api/v1/contrib/llmsearch/chat',
        type: 'POST',
        data: { json: sessionStorage.getItem('current_chat') },
        dataType: 'text',
        success: function(jsonText) {
            try {
                // Parser explicitement le JSON
                var data = JSON.parse(jsonText);
                
                if (data._debug_log) {
                    console.group('[LLMSearch] Debug log');
                    data._debug_log.forEach(function(entryStr) {
                        var entry = (typeof entryStr === 'string') ? JSON.parse(entryStr) : entryStr;
                        if (entry.request)   { console.group('Round ' + entry.round + ' [Request]');  console.log(entry.request);  console.groupEnd(); }
                        if (entry.response)  { console.group('Round ' + entry.round + ' [Response]'); console.log(entry.response); console.groupEnd(); }
                        if (entry.tool_call) { console.group('Round ' + entry.round + ' [tool] ' + entry.tool_call); console.log('Args:', entry.arguments); console.log('Result:', entry.tool_result); console.groupEnd(); }
                    });
                    console.groupEnd();
                }
                
                if (data.choices && data.choices.length > 0) {
                    const content = preprocessContent(data.choices[0].message.content);
                    const clean = DOMPurify.sanitize(content);
                    $('div.chat-messages div.assistant:last p').html(clean);
                    saveMessage('assistant', clean);
                    chatWindow.scrollTop(chatWindow[0].scrollHeight);
                }
            } catch (e) {
                console.error('Error parsing JSON:', e);
                alert('Error processing response. Check console.');
            }
        },
        error: function() {
            alert("AJAX error, check the plugin configuration or javascript console");
        }
    });
}

function addMessage(role, content, save=1) {
    var iconName = role == 'assistant' ? 'robot' : 'user';
    var messageDiv = $('<div>', { 'class': 'message ' + role });

    var icon = $('<i>', { 'class': 'fa-solid fa-' + iconName });

    // Utiliser .html() pour préserver les balises et l'encodage UTF-8
    var paragraph = $('<p>').html(content);
    messageDiv.append(icon);
    messageDiv.append(paragraph);
    $('div.chat-messages').append(messageDiv);
    if (save) saveMessage(role, content);
}

function saveMessage(role, content) {
    var current_chat = sessionStorage.getItem("current_chat");
    if (current_chat === null) {
	current_chat = [];
    }
    else {
	current_chat = JSON.parse(current_chat);
    }
    const message = {role:role, content:content};
    current_chat.push(message);
    sessionStorage.setItem("current_chat", JSON.stringify(current_chat));
}

function populateChat() {
    var current_chat = sessionStorage.getItem("current_chat");
    if (current_chat === null) {
        // No existing history — show the welcome message
        $.get('/api/v1/contrib/llmsearch/welcome', function(data) {
            addMessage('assistant', data, 0);
        });
    }
    else {
        // Restore existing conversation from session storage
        JSON.parse(current_chat).forEach(item => {
            addMessage(item.role, item.content, 0);
        });
    }
}

// Normalize LLM output before sanitization:
// 1. Use marked.js to convert Markdown (or pass-through HTML) to clean HTML
// 2. Strip any absolute origin from href attributes so all links are relative.
//    Uses a temporary DOM element + URL API for robust parsing — no regex fragility.
//    If the "host" part doesn't look like a real hostname (no dots, not localhost/IP),
//    treat it as the first path segment instead of discarding it.
//    e.g. http://localhost:8282/cgi-bin/... → /cgi-bin/...  (real host, strip it)
//         http://cgi-bin/koha/...          → /cgi-bin/...  (fake host, keep it)
function preprocessContent(content) {
    const html = marked.parse(content);
    // Parse into a temporary DOM to fix links properly using the URL API
    var temp = document.createElement('div');
    temp.innerHTML = html;
    temp.querySelectorAll('a[href]').forEach(function(a) {
        var href = a.getAttribute('href');
        // Normalise protocol-relative URLs (//host/path) so URL() can parse them
        var absolute = /^\/\//.test(href) ? 'https:' + href : href;
        try {
            var url = new URL(absolute);
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
            var host = url.hostname;
            if (/\./.test(host) || /^localhost$/.test(host)) {
                // Real hostname or localhost — strip the origin, keep path + query + hash
                a.setAttribute('href', url.pathname + url.search + url.hash);
            } else {
                // "Hostname" is actually a path segment (e.g. cgi-bin) — restore it
                a.setAttribute('href', '/' + host + url.pathname + url.search + url.hash);
            }
        } catch (e) {
            // Not a valid absolute URL — leave href unchanged
        }
    });
    return temp.innerHTML;
}

function resetChat() {
    sessionStorage.removeItem("current_chat");
    $('div.chat-messages').children().remove();
    populateChat();
}
