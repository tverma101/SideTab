package com.sidescreen.app

/**
 * Formats a host/port endpoint for display. An IPv6 literal gets RFC 3986
 * bracket notation (`[2603:…:17e7]:54321`); jamming the port onto the address
 * (`2603:…:17e7:54321`) is ambiguous — the port reads as one more address
 * group. Hostnames and IPv4 keep the plain `host:port` form.
 */
internal object EndpointFormat {
    fun of(host: String, port: Int): String {
        val literal = host.trim()
        val bracketed =
            when {
                literal.startsWith("[") -> literal
                literal.contains(':') -> "[$literal]"
                else -> literal
            }
        return "$bracketed:$port"
    }
}
