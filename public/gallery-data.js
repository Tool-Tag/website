// Add only real, finished ToolTag work. Empty = completely hidden section.
// Photos are selected in array order; featured:false excludes a photo from Home.
window.TOOLTAG_GALLERY = {
  homeLimit: 4, // 4–6 maximum; desktop always uses four visible columns.
  enableViewMore: false, // Enable later to open all real photos in the same modal.
  photos: []
};
// Example schema (documentation only; NOT a displayed sample):
// { src:'assets/work/battery-01.webp', full:'assets/work/battery-01-full.webp',
//   real:true, featured:true,
//   label:{en:'Battery · Name + Phone',es:'Batería · Nombre y teléfono'},
//   alt:{en:'Describe the actual photograph',es:'Describe la fotografía real'} }
