$(document).ready(function() 
    { 
        $("#resulttable").tablesorter( {headers: {0: {sorter: true}}, theme : 'blue', sortInitialOrder: 'desc', sortList: [[1,1]]} ); 
    } 
); 
