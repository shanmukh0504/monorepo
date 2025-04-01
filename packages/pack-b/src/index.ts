import { createUser, showUser, User } from 'pack-a';
import { createVehicle, showVehicle, Vehicle } from 'pack-c';

const user: User = createUser('Shanmukh', 21);
const vehicle: Vehicle = createVehicle('Bike', 2000);

showUser(user);
showVehicle(vehicle);
