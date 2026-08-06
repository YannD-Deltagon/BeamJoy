var app = angular.module('beamng.apps');

// phantom app: BeamNG's app-container grid tracks a position/size slot the real Angular
// activity window (modModules/beamjoy/windows/activity) is aligned to from Lua
app.directive('beamjoy-activity', [function () {
	return {
		template: '',
		replace: true,
		restrict: 'EA',
		scope: true,
	}
}]);
