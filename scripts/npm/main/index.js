"use strict";

const { resolve, packages } = require("./location");
module.exports = { resolve, packages, ...require("./binding") };
