
$(document).ready(function() {

    $( ".btn-delete" ).click(function() {
      var message = 'Are you sure you want to delete this location?';
        if (confirm(message)) {
            // delete...
            return true;
        }
        return false;
});

});

