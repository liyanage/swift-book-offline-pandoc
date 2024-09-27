return {
    {
      Image = function (elem)
        retina_suffix = '@2x.png'
        return pandoc.Image(elem.caption, elem.src .. retina_suffix, elem.title, elem.attr)
      end,
    }
  }
  