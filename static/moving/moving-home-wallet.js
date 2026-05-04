/**
 * Home page: load wallet JSON into localStorage (same format as staff app) and refresh move planner.
 */
(function () {
  function wire() {
    var input = document.getElementById('movingWalletFileInput');
    if (!input || !window.NHSWallet) return;
    input.addEventListener('change', function () {
      if (!input.files || !input.files[0]) {
        input.value = '';
        return;
      }
      var file = input.files[0];
      var reader = new FileReader();
      reader.onload = function () {
        try {
          var replace = window.confirm(
            'Replace your whole wallet with this file?\n\nOK = replace everything.\nCancel = merge with what is already in this browser.'
          );
          NHSWallet.loadWalletFromFileText(String(reader.result), replace ? 'replace' : 'merge')
            .then(function () {
              window.dispatchEvent(new CustomEvent('nhs-wallet-updated'));
              alert('Wallet loaded from "' + file.name + '". Checklist refreshed if it was already open.');
            })
            .catch(function (e) {
              alert(e.message || String(e));
            });
        } finally {
          input.value = '';
        }
      };
      reader.onerror = function () {
        alert('Could not read file.');
        input.value = '';
      };
      reader.readAsText(file, 'UTF-8');
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire);
  else wire();
})();
