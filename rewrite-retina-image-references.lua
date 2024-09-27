return {
    {
      Image = function (elem)
        if FORMAT:match 'latex' then
          -- Center images horizontally
          return {
            pandoc.RawInline('latex', '\\hfill\\break{\\centering'),
            elem,
            pandoc.RawInline('latex', '\\par}')
          }
        else
          return elem
        end
      end,
    }
  }
