// Copia el comando de Homebrew con un clic. Es el único JS de la página: sin él, el comando se selecciona a mano.
// Los textos vienen del HTML (data-copied, data-copied-status, data-selected-status), así sirve igual en /es/.
for (const button of document.querySelectorAll("[data-copy]")) {
  const source = document.getElementById(button.dataset.copy);
  const status = button.closest(".brew")?.querySelector("[role=status]");
  const label = button.textContent;
  let timer;

  button.addEventListener("click", async () => {
    const text = source.textContent.trim();
    let copied = false;
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch {
      // Sin acceso al portapapeles (http sin TLS, permiso negado): deja el comando seleccionado.
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    const { copied: done, copiedStatus, selectedStatus } = button.dataset;
    button.textContent = copied ? done : label;
    if (status) status.textContent = copied ? copiedStatus : selectedStatus;
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.textContent = label;
      if (status) status.textContent = "";
    }, 2000);
  });
}
