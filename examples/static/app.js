// httpx.zig SPA Example - Client-side JavaScript
document.addEventListener('DOMContentLoaded', function() {
    // Fetch button handler
    const fetchBtn = document.getElementById('fetch-btn');
    const output = document.getElementById('output');

    if (fetchBtn) {
        fetchBtn.addEventListener('click', async function() {
            output.textContent = 'Loading...';
            try {
                const response = await fetch('/static/index.html');
                const text = await response.text();
                output.textContent = 'Response length: ' + text.length + ' bytes\nStatus: ' + response.status;
            } catch (err) {
                output.textContent = 'Error: ' + err.message;
            }
        });
    }

    // Contact form handler
    const contactForm = document.getElementById('contact-form');
    const formOutput = document.getElementById('form-output');

    if (contactForm) {
        contactForm.addEventListener('submit', function(e) {
            e.preventDefault();
            const formData = new FormData(contactForm);
            const data = Object.fromEntries(formData.entries());
            formOutput.textContent = 'Form submitted:\n' + JSON.stringify(data, null, 2);
            contactForm.reset();
        });
    }

    // Active nav link
    const path = window.location.pathname;
    document.querySelectorAll('.nav-link').forEach(function(link) {
        if (link.getAttribute('href') === path) {
            link.classList.add('active');
        }
    });
});
