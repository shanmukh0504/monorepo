"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
var pack_a_1 = require("pack-a");
var pack_c_1 = require("pack-c");
var user = (0, pack_a_1.createUser)('Shanmukh', 21);
var vehicle = (0, pack_c_1.createVehicle)('Car', 2015);
(0, pack_a_1.showUser)(user);
(0, pack_c_1.showVehicle)(vehicle);
