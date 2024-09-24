return {
    {
      Image = function (elem)
        if elem.src == 'CollectionTypes_intro' then
            retina_suffix = '_2x.png'
        else
            retina_suffix = '@2x.png'
        end
        return pandoc.Image(elem.caption, elem.src .. retina_suffix, elem.title, elem.attr)
      end,
    }
  }
  