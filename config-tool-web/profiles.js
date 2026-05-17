// HID Remapper profile manager.
//
// Stores named profiles (full config JSON) in localStorage and provides a
// fingerprinting routine matching the CLI tool so we can label the live
// device config with its profile name.

const STORAGE_KEY = 'remapper_profiles_v1';

export function load_profiles() {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (!raw) return {};
        const parsed = JSON.parse(raw);
        return (parsed && typeof parsed === 'object') ? parsed : {};
    } catch (e) {
        console.warn('profiles: failed to read localStorage', e);
        return {};
    }
}

export function save_profiles(profiles) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(profiles));
}

export function list_profile_names() {
    return Object.keys(load_profiles()).sort((a, b) => a.localeCompare(b));
}

export function get_profile(name) {
    const profiles = load_profiles();
    return profiles[name] || null;
}

export function save_profile(name, config) {
    const profiles = load_profiles();
    profiles[name] = JSON.parse(JSON.stringify(config));
    save_profiles(profiles);
}

export function delete_profile(name) {
    const profiles = load_profiles();
    delete profiles[name];
    save_profiles(profiles);
}

// Try to fetch profile JSON files served from disk (profiles/ folder next to
// the web tool). Returns the list of names that were successfully imported.
// Silently does nothing when the page is served from a host that doesn't
// expose the folder (e.g. remapper.org).
export async function auto_import_from_server() {
    let manifest;
    try {
        const r = await fetch('./profiles-manifest.json', { cache: 'no-cache' });
        if (!r.ok) return [];
        manifest = await r.json();
    } catch (e) {
        return [];
    }
    if (!Array.isArray(manifest)) return [];
    const imported = [];
    for (const name of manifest) {
        if (typeof name !== 'string' || !name) continue;
        try {
            const r = await fetch(`./profiles/${encodeURIComponent(name)}.json`, { cache: 'no-cache' });
            if (!r.ok) continue;
            const data = await r.json();
            save_profile(name, data);
            imported.push(name);
        } catch (e) {
            console.warn(`profiles: failed to auto-import ${name}`, e);
        }
    }
    return imported;
}

// ---- Fingerprinting (must match remapper-profile-status.py) ----

const FINGERPRINT_KEYS = [
    'unmapped_passthrough_layers',
    'partial_scroll_timeout',
    'tap_hold_threshold',
    'gpio_debounce_time_ms',
    'interval_override',
    'our_descriptor_number',
    'ignore_auth_dev_inputs',
    'macro_entry_duration',
    'gpio_output_mode',
    'normalize_gamepad_inputs',
    'mappings',
    'macros',
    'expressions',
    'quirks',
];

function normalise_mapping(m) {
    const src = (m.source_usage || '').toLowerCase();
    const tgt = (m.target_usage || '').toLowerCase();
    if ((src === '0x00000000' || src === '0x0') &&
        (tgt === '0x00000000' || tgt === '0x0')) {
        return null;
    }
    return {
        source_usage: src,
        target_usage: tgt,
        scaling: m.scaling ?? 1000,
        layers: [...(m.layers || [])].sort((a, b) => a - b),
        sticky: !!m.sticky,
        tap: !!m.tap,
        hold: !!m.hold,
        source_port: m.source_port ?? 0,
        target_port: m.target_port ?? 0,
    };
}

function stable_stringify(value) {
    if (Array.isArray(value)) {
        return '[' + value.map(stable_stringify).join(',') + ']';
    }
    if (value && typeof value === 'object') {
        const keys = Object.keys(value).sort();
        return '{' + keys.map(k => JSON.stringify(k) + ':' + stable_stringify(value[k])).join(',') + '}';
    }
    return JSON.stringify(value);
}

function canonicalise(config) {
    const out = {};
    for (const key of FINGERPRINT_KEYS) {
        const val = config[key];
        if (key === 'mappings') {
            const mapped = (val || []).map(normalise_mapping).filter(Boolean);
            mapped.sort((a, b) => {
                if (a.source_usage !== b.source_usage) return a.source_usage < b.source_usage ? -1 : 1;
                if (a.target_usage !== b.target_usage) return a.target_usage < b.target_usage ? -1 : 1;
                return JSON.stringify(a.layers).localeCompare(JSON.stringify(b.layers));
            });
            out[key] = mapped;
        } else if (key === 'macros') {
            const macros = [...(val || [])];
            while (macros.length && (!macros[macros.length - 1] || macros[macros.length - 1].length === 0)) {
                macros.pop();
            }
            out[key] = macros;
        } else if (key === 'expressions') {
            const exprs = [...(val || [])];
            while (exprs.length && !exprs[exprs.length - 1]) {
                exprs.pop();
            }
            out[key] = exprs;
        } else if (key === 'quirks') {
            const quirks = [...(val || [])];
            quirks.sort((a, b) => stable_stringify(a).localeCompare(stable_stringify(b)));
            out[key] = quirks;
        } else {
            out[key] = val ?? null;
        }
    }
    return out;
}

async function sha256_hex(s) {
    const buf = new TextEncoder().encode(s);
    const hash = await crypto.subtle.digest('SHA-256', buf);
    return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, '0')).join('');
}

export async function fingerprint(config) {
    return sha256_hex(stable_stringify(canonicalise(config)));
}

export async function identify_profile(config) {
    const fp = await fingerprint(config);
    const profiles = load_profiles();
    for (const name of Object.keys(profiles)) {
        const pfp = await fingerprint(profiles[name]);
        if (pfp === fp) return { name, fingerprint: fp };
    }
    return { name: null, fingerprint: fp };
}
