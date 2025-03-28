export interface Vehicle {
    name: string;
    age: number;
}

export const createVehicle = (name: string, age: number): Vehicle => ({ name, age });

export const showVehicle = (vehicle: Vehicle) => console.log(`${vehicle.name} is ${vehicle.age} years old now.`);
