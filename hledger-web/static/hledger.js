/* hledger web ui javascript */

//----------------------------------------------------------------------
// STARTUP

$(document).ready(function() {
  initGlobal();
  initPage();
  initAjaxNav();
});

// Wiring tied to persistent DOM (outside #main-content); bind once.
function initGlobal() {
  // keyboard shortcuts
  // 'body' seems to hold focus better than document in FF
  $('body').bind('keydown', 'h',       function(){ $('#helpmodal').modal('toggle'); return false; });
  $('body').bind('keydown', 'shift+/', function(){ $('#helpmodal').modal('toggle'); return false; });
  $('body').bind('keydown', 'j',       function(){ location.href = document.hledgerWebBaseurl+'/journal'; return false; });
  $('body').bind('keydown', 's',       function(){ sidebarToggle(); return false; });
  $('body').bind('keydown', 'e',       function(){ emptyAccountsToggle(); return false; });
  $('body').bind('keydown', 'a',       function(){ addformShow(); return false; });
  $('body').bind('keydown', 'n',       function(){ addformShow(); return false; });
  $('body').bind('keydown', 'f',       function(){ $('#searchform input').focus(); return false; });

  $(window).on('hashchange', highlightHash);

  $('[data-toggle="offcanvas"]').click(function () {
      $('.row-offcanvas').toggleClass('active');
  });
}

// Wiring tied to elements inside #main-content; re-run on load and after every
// AJAX swap. Handlers are namespaced and cleared first to avoid double-binding.
function initPage() {

  // add form helpers XXX move to addForm ?

  // date picker
  // http://bootstrap-datepicker.readthedocs.io/en/latest/options.html
  var dateEl = $('#dateWrap').datepicker({
    showOnFocus: false,
    autoclose: true,
    format: 'yyyy-mm-dd',
    todayHighlight: true,
    weekStart: 1 // Monday
  });

  // focus and pre-fill the add form whenever it is shown
  $('#addmodal')
    .off('shown.bs.modal.hledger hidden.bs.modal.hledger')
    .on('shown.bs.modal.hledger', function() {
      addformFocus();
    })
    .on('hidden.bs.modal.hledger', function() {
      // close the date picker if open
      dateEl.datepicker('hide');
    });

  // ensure that the keypress listener on the final amount input is always active
  $('#addform')
    .off('focus.hledger')
    .on('focus.hledger', '.amount-input:last', function() {
      addformLastAmountBindKey();
    });

  // highlight the entry from the url hash
  highlightHash();
}

function highlightHash() {
  $('.highlighted').removeClass('highlighted');
  if (window.location.hash && $(window.location.hash)[0]) {
    $(window.location.hash).addClass('highlighted');
  }
}

//----------------------------------------------------------------------
// AJAX NAVIGATION
// Progressive enhancement: for same-origin journal/register links, swap only
// #main-content in place instead of reloading the page, so the sidebar (and its
// scroll position) never moves. Ordinary hrefs remain the fallback when this is
// unsupported, on any error, or for modified/cross-origin clicks.

function initAjaxNav() {
  if (!window.history || !window.history.pushState || !window.DOMParser || !window.URL) {
    return;
  }
  $(document)
    .off('click.hledgerAjax')
    .on('click.hledgerAjax', '#sidebar-menu a[href], #main-content a[href]', function(ev) {
      if (ev.which > 1 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
      if (this.target && this.target !== '_self') return;
      var url = new URL(this.href, window.location.href);
      if (url.origin !== window.location.origin || !isAjaxNavPath(url.pathname)) return;
      ev.preventDefault();
      ajaxNavigate(this.href, true);
    });
  $(window)
    .off('popstate.hledgerAjax')
    .on('popstate.hledgerAjax', function() {
      ajaxNavigate(window.location.href, false);
    });
}

function isAjaxNavPath(pathname) {
  var base = new URL(document.hledgerWebBaseurl, window.location.href).pathname.replace(/\/+$/, '');
  var path = pathname.replace(/\/+$/, '');
  return path === base + '/journal' || path === base + '/register';
}

function ajaxNavigate(href, pushHistory) {
  $.ajax({ url: href, method: 'GET', dataType: 'html', cache: false })
    .done(function(html) {
      if (!applyAjaxPage(html, href, pushHistory)) window.location.href = href;
    })
    .fail(function() {
      window.location.href = href;
    });
}

function applyAjaxPage(html, href, pushHistory) {
  var doc = new DOMParser().parseFromString(html, 'text/html');
  var newMain = doc.querySelector('#main-content');
  var newSidebar = doc.querySelector('#sidebar-menu');
  if (!newMain || !newSidebar) return false;

  // Refresh the account list (so the active-account highlight moves) while
  // preserving the sidebar's own scroll position.
  var $sidebar = $('#sidebar-menu');
  var sidebarScroll = $sidebar.scrollTop();
  $sidebar.find('.main-menu').replaceWith($(newSidebar).find('.main-menu'));
  $sidebar.scrollTop(sidebarScroll);

  // Swap the main content. Detach its scripts first so jQuery doesn't run them
  // on insert; we run them explicitly afterwards.
  var $newMain = $(newMain);
  var scripts = $newMain.find('script').remove().toArray();
  $('#main-content').replaceWith($newMain);
  $newMain.scrollTop(0);

  if (doc.title) document.title = doc.title;
  if (pushHistory) window.history.pushState({hledgerAjax: true}, doc.title || '', href);

  runScripts(scripts);
  initPage();
  return true;
}

// Re-execute <script>s pulled from swapped-in content. Their
// $(document).ready callbacks run immediately, since the document is ready.
function runScripts(scripts) {
  $.each(scripts, function(_i, s) {
    if (s.src) {
      $.ajax({ url: s.src, dataType: 'script', async: false });
    } else {
      $.globalEval(s.text || s.textContent || s.innerHTML || '');
    }
  });
}

//----------------------------------------------------------------------
// HELPERS

// Decode a base64-encoded UTF-8 string. Defined once here (rather than in a
// template) so it is always available, including to scripts re-run after an
// AJAX navigation. Used by add-form values encoded server-side (AddForm.hs).
var utf8textdecoder = new TextDecoder();
function decodeBase64EncodedText(b64) {
  var unb64 = window.atob(b64);
  var arr = new Uint8Array(unb64.length);
  for (var i = 0; i < arr.length; i++) {
    arr[i] = unb64.charCodeAt(i);
  }
  return utf8textdecoder.decode(arr);
}

//----------------------------------------------------------------------
// ADD FORM

function addformShow(showmsg) {
  showmsg = typeof showmsg !== 'undefined' ? showmsg : false;
  addformReset(showmsg);
  $('#addmodal').modal('show');
}

// Make sure the add form is empty and clean and has the default number of rows.
function addformReset(showmsg) {
  showmsg = typeof showmsg !== 'undefined' ? showmsg : false;
  if ($('form#addform').length > 0) {
    if (!showmsg) $('div#message').html('');
    $('#addform .account-group.added-row').remove();
    addformLastAmountBindKey();
    $('#addform')[0].reset();
    // reset typehead state (though not fetched completions)
    $('.typeahead').typeahead('val', '');
    $('.tt-dropdown-menu').hide();
  }
}

// Set the add-new-row-on-keypress handler on the add form's current last amount field, only.
// (NB: removes all other keypress handlers from all amount fields).
function addformLastAmountBindKey() {
  $('input[name=amount]').off('keypress');
  $('input[name=amount]:last').keypress(addformAddPosting);
}

// Pre-fill today's date and focus the description field in the add form.
function addformFocus() {
  $('#addform input[name=date]').val(isoDate());
  focus($('#addform input[name=description]'));
}

function isoDate() {
  return new Date().toLocaleDateString("sv");  // https://stackoverflow.com/a/58633651/84401
}

// Focus a jquery-wrapped element, working around http://stackoverflow.com/a/7046837.
function focus($el) {
  setTimeout(function (){
    $el.focus();
  }, 0);
}

// Insert another posting row in the add form.
function addformAddPosting() {
  if (!$('#addform').is(':visible')) { return; }

  // Clone the last row.
  var newrow = $('#addform .account-group:last').clone().addClass('added-row');
  var newnum = $('#addform .account-group').length + 1;

  // Clear the new account and amount fields and update their placeholder text.
  var accountfield = newrow.find('input[name=account]');
  var amountfield  = newrow.find('input[name=amount]');
  accountfield.val('').prop('placeholder', 'Account '+newnum);
  amountfield.val('').prop('placeholder', 'Amount '+newnum);

  // Enable autocomplete in the new account field.
  // We must first remove these typehead helper elements cloned from the old row,
  // or it will recursively add helper elements for those, causing confusion (#2215).
  newrow.find('.tt-hint').remove();
  newrow.find('.tt-input').removeClass('tt-input');
  accountfield.typeahead({ highlight: true }, { source: globalThis.accountsCompleter.ttAdapter() });

  // Add the new row to the page.
  $('#addform .account-postings').append(newrow);

  // And move the keypress handler to the new last amount field.
  addformLastAmountBindKey();
}

// Remove the add form's last posting row, if empty, keeping at least two.
function addformDeletePosting() {
  if ($('#addform .account-group').length <= 2) {
    return;
  }
  // remember if the last row's field or button had focus
  var focuslost =
    $('.account-input:last').is(':focus')
    || $('.amount-input:last').is(':focus');
  // delete last row
  $('#addform .account-group:last').remove();
  if (focuslost) {
    focus($('.account-input:last'));
  }
  // move the keypress handler to the new last amount field
  addformLastAmountBindKey();
}

//----------------------------------------------------------------------
// SIDEBAR

function sidebarToggle() {
  $('#sidebar-menu').toggleClass('col-md-4 col-sm-4 col-any-0');
  $('#main-content').toggleClass('col-md-8 col-sm-8 col-md-12 col-sm-12');
  $('#spacer').toggleClass('col-md-4 col-sm-4 col-any-0');
  $.cookie('showsidebar', $('#sidebar-menu').hasClass('col-any-0') ? '0' : '1');
}

function emptyAccountsToggle() {
  $('.acct.empty').parent().toggleClass('hide');
  $.cookie('hideemptyaccts', $.cookie('hideemptyaccts') === '1' ? '0' : '1')
}
