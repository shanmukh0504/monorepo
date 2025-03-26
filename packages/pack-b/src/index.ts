import { createUser, showUser, User } from 'pack-a';
import { createVehicle, showVehicle, Vehicle } from 'pack-c';

const user: User = createUser('Shanmukh', 21);
const vehicle: Vehicle = createVehicle('Car', 2021);

showUser(user);
showVehicle(vehicle);
