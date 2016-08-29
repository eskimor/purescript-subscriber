/* global exports */
"use strict";
// jshint maxparams: 4
exports._lookup = function (no, yes, k, m) {
    return k in m ? yes(m[k]) : no;
}
